#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
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
export PI_PACKAGE_DIR="$PI_PACKAGE_DIR"
export ROOT="$ROOT"
export MODULE="$ROOT/.pi/extensions/lib/fm-autonomy.ts"
export CORPUS="$ROOT/tests/fixtures/fm-autonomy-heldout.json"
export PROMPT_SCRIPT="$ROOT/bin/fm-autonomy-prompt.sh"
export SESSION_DIR="$TMP_ROOT/sessions"
export FM_PI_AUTONOMY_LIVE_PROVIDER="$FM_PI_AUTONOMY_LIVE_PROVIDER"
export FM_PI_AUTONOMY_LIVE_MODEL="$FM_PI_AUTONOMY_LIVE_MODEL"
export FM_PI_AUTONOMY_CAPTURE_OUTPUT="${FM_PI_AUTONOMY_CAPTURE_OUTPUT:-}"
node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const sdk = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const autonomy = await import(pathToFileURL(process.env.MODULE).href);
const corpusBytes = readFileSync(process.env.CORPUS);
const corpus = JSON.parse(corpusBytes);
const testCase = corpus.cases.find((candidate) => candidate.id === "routine-operation-still-wakes");
assert(testCase, "live guard case is missing");
const captureOutput = process.env.FM_PI_AUTONOMY_CAPTURE_OUTPUT;
const selectedCases = captureOutput ? corpus.cases : [testCase];

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
const capturedOutputs = [];
const captureRecords = [];
const evaluation = await autonomy.evaluateHeldOutClassifier(selectedCases, {
  async classify(batch) {
    pendingBatch = batch;
    const decision = new Promise((resolve) => { resolveDecision = resolve; });
    let timeoutId;
    const timeout = new Promise((_, reject) => {
      timeoutId = setTimeout(() => reject(new Error("live autonomy classifier timed out")), 120000);
      timeoutId.unref?.();
    });
    try {
      await created.session.prompt([
        `AUTONOMY BATCH ${batch.id}`,
        `Decision contract fingerprint: ${autonomy.decisionContractFingerprint()}`,
        "Account for every event exactly once and finish with fm_supervision_decide.",
        JSON.stringify({ batchId: batch.id, events: batch.events }),
      ].join("\n\n"));
      const output = await Promise.race([decision, timeout]);
      const caseId = batch.events[0].id.split(":").slice(1, -1).join(":");
      capturedOutputs.push({ caseId, decision: output });
      captureRecords.push({
        caseId,
        batchId: batch.id,
        inputSha256: createHash("sha256").update(autonomy.canonicalJson(batch)).digest("hex"),
        outputSha256: createHash("sha256").update(autonomy.canonicalJson(output)).digest("hex"),
      });
      return output;
    } finally {
      clearTimeout(timeoutId);
    }
  },
});
created.session.dispose();
assert.equal(evaluation.failed, 0, JSON.stringify(evaluation));
if (captureOutput) {
  const outputPath = resolve(captureOutput);
  const root = resolve(process.env.ROOT);
  if (outputPath !== root && !outputPath.startsWith(`${root}${sep}`)) throw new Error("capture output must stay inside the worktree");
  const promptSha256 = createHash("sha256").update(execFileSync("bash", [process.env.PROMPT_SCRIPT])).digest("hex");
  const runtimePackage = JSON.parse(readFileSync(`${process.env.PI_PACKAGE_DIR}/package.json`, "utf8"));
  const artifact = {
    schema: "fm-autonomy-recorded-outputs.v1",
    capturedAt: new Date().toISOString(),
    provenance: {
      captureInterface: "DecisionClassifier.classify -> fm_supervision_decide -> validateDecision",
      captureMode: "pi-agent-session",
      provider: process.env.FM_PI_AUTONOMY_LIVE_PROVIDER,
      model: process.env.FM_PI_AUTONOMY_LIVE_MODEL,
      runtime: `pi-coding-agent@${runtimePackage.version}`,
      runId: randomUUID(),
      corpusSchema: corpus.schema,
      corpusSha256: createHash("sha256").update(corpusBytes).digest("hex"),
      contractFingerprint: autonomy.decisionContractFingerprint(),
      promptSha256,
      caseCount: selectedCases.length,
      records: captureRecords,
    },
    outputs: capturedOutputs,
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  const temporary = `${outputPath}.tmp-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, outputPath);
}
console.log("ok - real configured Pi autonomy session classified through the production decision tool");
JS

pass "live configured-model Pi autonomy guard passes without Linear or project mutation"
