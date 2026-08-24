import { readFileSync } from "node:fs";

const TOOL_NAME = "submit_crosscheck_verdict";

export default function registerCrosscheckVerdict(pi) {
	const schemaPath = process.env.FM_CROSSCHECK_REVIEW_SCHEMA;
	if (!schemaPath) {
		throw new Error("FM_CROSSCHECK_REVIEW_SCHEMA is required");
	}
	const parameters = JSON.parse(readFileSync(schemaPath, "utf8"));
	pi.registerTool({
		name: TOOL_NAME,
		label: "Submit Crosscheck verdict",
		description:
			"Submit the complete final Crosscheck verdict. Use this exactly once as the final action after all review work is complete.",
		promptSnippet: "Submit the complete final Crosscheck verdict",
		promptGuidelines: [
			"Use submit_crosscheck_verdict exactly once as the final action.",
			"Do not emit a final text verdict before or after this tool call.",
		],
		parameters,
		constrainedSampling: { type: "json_schema", strict: "require" },
		async execute(_toolCallId, verdict) {
			return {
				content: [{ type: "text", text: "Crosscheck verdict accepted for host validation." }],
				details: { accepted: true },
				terminate: true,
			};
		},
	});
}
