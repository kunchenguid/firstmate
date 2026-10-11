/** Exercise real Codemode in a private Pi TUI without accounts or fleet records. */
import { appendFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/** Register the deterministic provider, test-only outcome tool and prompt commands. */
export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "calm-codemode-test-api",
    provider: "calm-codemode-test",
    models: [{
      id: "deterministic", name: "Calm Codemode test", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1024,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("calm-codemode-test", {
    baseUrl: "http://127.0.0.1/unused", apiKey: "test-only", api: faux.api, models: faux.models,
    /** Capture provider context while every model response stays local. */
    streamSimple(model, context, options) {
      appendFileSync(process.env.CODEMODE_CONTEXT!, JSON.stringify(context) + "\n");
      return faux.streamSimple(model, context, options);
    },
  });
  /** Mark extension binding complete before the test submits any command. */
  pi.on("session_start", (_event, ctx) => {
    const capability = typeof pi.registerToolRenderer === "function" ? "AVAILABLE" : "UNAVAILABLE";
    ctx.ui.setStatus("codemode-test", `CODEMODE_TEST_READY CODEMODE_RENDERER_${capability}`);
  });
  pi.registerTool({
    name: "fm_branch_outcomes", label: "fm_branch_outcomes", description: "Read isolated test outcomes.",
    parameters: Type.Object({ recent: Type.Optional(Type.Number()) }),
    /** Return outcome-shaped text and usage without opening any fleet store. */
    async execute() {
      return {
        content: [{ type: "text", text: "OUTCOME_PRIVATE_RAW\nseq=7 verdict=routine summary=TEST_ONLY\nseq=6 verdict=routine summary=TEST_ONLY\nseq=5 verdict=routine summary=TEST_ONLY\nseq=4 verdict=routine summary=TEST_ONLY\nOUTCOME_EXPANDED_TAIL" }],
        details: {}, usage: { input: 11, output: 2, totalTokens: 13, cost: { total: 0.0002 } },
      };
    },
  });
  for (const kind of ["tool_execution_start", "tool_execution_end"] as const) {
    /** Record the actual agent-loop parent/child events without changing them. */
    pi.on(kind, (event) => {
      appendFileSync(process.env.CODEMODE_EVENTS!, JSON.stringify({ kind, ...event }) + "\n");
    });
  }
  pi.registerCommand("calm-codemode-baseline", {
    description: "Draw the no-tool baseline.",
    /** Measure the normal user-to-final spacing through a genuine prompt. */
    handler: async () => {
      faux.setResponses([fauxAssistantMessage([fauxText("BASELINE_FINAL")])]);
      pi.sendUserMessage("GENUINE_BASELINE");
    },
  });
  pi.registerCommand("calm-codemode-test", {
    description: "Run the reported nested read and outcome script twice.",
    /** Execute real repeated Codemode calls plus an ordinary read comparison. */
    handler: async () => {
      const code = 'text(await tools.read({path:"sample.txt"}));\ntext(await tools.fm_branch_outcomes({recent:2}));';
      faux.setResponses([
        fauxAssistantMessage([fauxToolCall("read", { path: "ordinary.txt" }, { id: "ordinary-read" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("codemode", { code }, { id: "code-one" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("codemode", { code }, { id: "code-two" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxText("AFTER_CODEMODE")]),
      ]);
      pi.sendUserMessage("GENUINE_CODEMODE");
    },
  });
}
