// Fleet pipeline rule: literal-path recursive deletes (installed by firstmate-addons pipeline-literal-delete/install.sh).
// Pipeline gate agents run pi with project context files disabled, but user-level extensions still load,
// so this reaches every pi session - review, test, document, lint steps - in every firstmate home.
import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const RULE = readFileSync("__RULE_PATH__", "utf8").trim();

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", async (event) => ({
		systemPrompt: `${event.systemPrompt}\n\n## Fleet delete rule\n\n${RULE}\n`,
	}));
}
