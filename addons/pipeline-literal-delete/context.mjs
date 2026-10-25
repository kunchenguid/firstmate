// Claude Code SessionStart hook: put the fleet literal-path delete rule into every session's context
// (installed by firstmate-addons pipeline-literal-delete/install.sh; reaches pipeline gate agents and workers alike).
import { readFileSync } from "node:fs";

const rule = readFileSync(new URL("./rule.txt", import.meta.url), "utf8").trim();
process.stdout.write(
	JSON.stringify({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: rule } }),
);
