// Fleet kill guard for pi (installed by firstmate-addons kill-guard/install.sh).
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { guard } from "__GUARD__";

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (event.toolName !== "bash") return undefined;
		const reason = guard((event.input as { command?: unknown }).command);
		return reason === null ? undefined : { block: true, reason };
	});
}
