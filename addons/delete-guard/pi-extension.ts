// Fleet delete guard for pi (installed by firstmate-addons delete-guard/install.sh; replaces the earlier pi-only stopgap).
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { guard } from "__GUARD__";

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;
		const command = (event.input as { command?: unknown }).command;
		const reason = guard(command, { cwd: (ctx as { cwd?: string }).cwd ?? process.cwd(), runtime: "pi" });
		return reason === null ? undefined : { block: true, reason };
	});
}
