#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_PI_AUTONOMY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_AUTONOMY_LIVE_E2E=1 to run the configured-model autonomy guard"
  exit 0
fi

: "${FM_PI_AUTONOMY_LIVE_PROVIDER:?set FM_PI_AUTONOMY_LIVE_PROVIDER}"
: "${FM_PI_AUTONOMY_LIVE_MODEL:?set FM_PI_AUTONOMY_LIVE_MODEL}"

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/dist/index.js" ] || fail "Pi package absent at $PI_PACKAGE_DIR"

TMP_ROOT=$(fm_test_tmproot fm-pi-autonomy-live)
PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
MODULE="$ROOT/.pi/extensions/lib/fm-autonomy.ts" \
CORPUS="$ROOT/tests/fixtures/fm-autonomy-heldout.json" \
PROMPT_SCRIPT="$ROOT/bin/fm-autonomy-prompt.sh" \
SESSION_DIR="$TMP_ROOT/sessions" \
FM_PI_AUTONOMY_LIVE_PROVIDER="$FM_PI_AUTONOMY_LIVE_PROVIDER" \
FM_PI_AUTONOMY_LIVE_MODEL="$FM_PI_AUTONOMY_LIVE_MODEL" \
node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const sdk = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const autonomy = await import(pathToFileURL(process.env.MODULE).href);
const corpus = JSON.parse(readFileSync(process.env.CORPUS, "utf8"));
const testCase = corpus.cases.find((candidate) => candidate.id === "routine-operation-still-wakes");
assert(testCase, "live guard case is missing");

const signal = AbortSignal.timeout(15000);
const runtime = await sdk.ModelRuntime.create({ allowModelNetwork: false, signal });
const available = await runtime.getAvailable(process.env.FM_PI_AUTONOMY_LIVE_PROVIDER, { signal });
const model = available.find((candidate) => candidate.id === process.env.FM_PI_AUTONOMY_LIVE_MODEL);
assert(model, "configured live autonomy model is unavailable");
assert(await runtime.getAuth(model, { signal }), "configured live autonomy model is unauthenticated");

mkdirSync(process.env.SESSION_DIR, { recursive: true });
const loader = new sdk.DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir: sdk.getAgentDir(),
  noExtensions: true,
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
  systemPrompt: execFileSync("bash", [process.env.PROMPT_SCRIPT], { encoding: "utf8" }),
});
await loader.reload();
const sessionManager = sdk.SessionManager.create(process.cwd(), process.env.SESSION_DIR);
let pendingBatch;
let resolveDecision;
const decisionTool = {
  name: "fm_supervision_decide",
  label: "Route supervision events",
  description: "Return the one final structured routing decision for the offered event batch.",
  parameters: {
    type: "object",
    additionalProperties: false,
    required: ["batchId", "action", "eventIds", "summary", "reasonCodes", "workClaims"],
    properties: {
      batchId: { type: "string" },
      action: { type: "string", enum: ["coalesce", "nextTurn", "wake"] },
      eventIds: { type: "array", items: { type: "string" } },
      summary: { type: "string" },
      reasonCodes: { type: "array", items: { type: "string" } },
      workClaims: { type: "array", items: { type: "object" } },
    },
  },
  async execute(_toolCallId, params) {
    const decision = autonomy.createDecision(params);
    resolveDecision(autonomy.validateDecision(decision, pendingBatch));
    return { content: [{ type: "text", text: `accepted ${decision.id}` }], details: { decisionId: decision.id }, terminate: true };
  },
};
const created = await sdk.createAgentSession({
  cwd: process.cwd(),
  sessionManager,
  resourceLoader: loader,
  tools: ["fm_supervision_decide"],
  customTools: [decisionTool],
  model: { ...model, maxTokens: Math.min(model.maxTokens, 1024) },
  modelRuntime: runtime,
  thinkingLevel: "low",
});
assert(created.session.model, "real autonomy AgentSession has no model");
const evaluation = await autonomy.evaluateHeldOutClassifier([testCase], {
  async classify(batch) {
    pendingBatch = batch;
    const decision = new Promise((resolve) => { resolveDecision = resolve; });
    const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("live autonomy classifier timed out")), 120000));
    await created.session.prompt([
      `AUTONOMY BATCH ${batch.id}`,
      `Decision contract fingerprint: ${autonomy.decisionContractFingerprint()}`,
      "Account for every event exactly once and finish with fm_supervision_decide.",
      JSON.stringify({ batchId: batch.id, events: batch.events }),
    ].join("\n\n"));
    return Promise.race([decision, timeout]);
  },
});
created.session.dispose();
assert.equal(evaluation.failed, 0, JSON.stringify(evaluation));
console.log("ok - real configured Pi autonomy session classified through the production decision tool");
JS

pass "live configured-model Pi autonomy guard passes without Linear or project mutation"
