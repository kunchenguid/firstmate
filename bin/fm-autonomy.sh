#!/usr/bin/env bash
# fm-autonomy.sh - local setup, doctor, status, kill-switch, and held-out
# verification surface for Pi Linear autonomy.
#
# Usage:
#   fm-autonomy.sh doctor
#   fm-autonomy.sh status
#   fm-autonomy.sh kill-on
#   fm-autonomy.sh kill-off
#   fm-autonomy.sh eval
#
# doctor validates the single config owner (config/pi-autonomy.json), checks
# the credential's PRESENCE without printing its value, verifies repository
# mappings and registered project autonomy through the deep TypeScript module,
# and confirms the explicitly selected supervision model is available through
# Pi's local ModelRuntime without refreshing a network catalog.
#
# status prints the same sanitized JSON plus durable journal/cache/cost totals.
# It creates no state when configuration is absent.
#
# kill-on atomically creates state/autonomy/KILL. The kill switch prevents new
# intake and claims but deliberately preserves existing journal and claim work
# for Pi-session reconciliation. kill-off removes only that marker.
#
# eval runs the held-out routing/collision corpus and refuses when its accepted
# decision-contract or prompt baseline changed without an updated baseline.
#
# This wrapper contains no config schema or orchestration logic. The deep module
# .pi/extensions/lib/fm-autonomy.ts is the single owner; this script only invokes
# its exported executable interface under the Node floor required by Pi.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
ACTION=${1:-status}

case "$ACTION" in
  doctor|status|kill-on|kill-off|eval) ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    echo "error: usage: fm-autonomy.sh doctor|status|kill-on|kill-off|eval" >&2
    exit 2
    ;;
esac
[ "$#" -eq 1 ] || {
  echo "error: usage: fm-autonomy.sh doctor|status|kill-on|kill-off|eval" >&2
  exit 2
}

command -v node >/dev/null 2>&1 || {
  echo "error: Pi autonomy requires Node 22.19 or newer" >&2
  exit 1
}
NODE_VERSION=$(node -p 'process.versions.node')
NODE_MAJOR=${NODE_VERSION%%.*}
NODE_REST=${NODE_VERSION#*.}
NODE_MINOR=${NODE_REST%%.*}
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 19 ]; }; then
  echo "error: Pi autonomy requires Node 22.19 or newer (found $NODE_VERSION)" >&2
  exit 1
fi

if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
  PI_PACKAGE_DIR=$FM_PI_PACKAGE_DIR
elif command -v npm >/dev/null 2>&1; then
  PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
else
  PI_PACKAGE_DIR=
fi
export FM_AUTONOMY_ROOT=$FM_ROOT
export FM_AUTONOMY_HOME=$FM_HOME
export FM_AUTONOMY_STATE=$STATE
export FM_AUTONOMY_CONFIG=$CONFIG
export FM_AUTONOMY_DATA=$DATA
export FM_AUTONOMY_PROJECTS=$PROJECTS
export FM_AUTONOMY_ACTION=$ACTION
export FM_AUTONOMY_PI_PACKAGE=$PI_PACKAGE_DIR

node --experimental-strip-types --input-type=module <<'NODE'
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.FM_AUTONOMY_ROOT;
const home = process.env.FM_AUTONOMY_HOME;
const state = process.env.FM_AUTONOMY_STATE;
const configDir = process.env.FM_AUTONOMY_CONFIG;
const data = process.env.FM_AUTONOMY_DATA;
const projects = process.env.FM_AUTONOMY_PROJECTS;
const action = process.env.FM_AUTONOMY_ACTION;
const modulePath = join(root, ".pi", "extensions", "lib", "fm-autonomy.ts");
const autonomy = await import(pathToFileURL(modulePath).href);
const configPath = join(configDir, "pi-autonomy.json");
const killPath = join(state, "autonomy", "KILL");
const containsCredential = (value, credential) => {
  if (!credential) return false;
  if (typeof value === "string") return value.includes(credential);
  if (Array.isArray(value)) return value.some((item) => containsCredential(item, credential));
  return value && typeof value === "object" ? Object.values(value).some((item) => containsCredential(item, credential)) : false;
};

if (action === "kill-on" || action === "kill-off") {
  if (!existsSync(configPath)) {
    console.error("error: config/pi-autonomy.json is absent; the feature is already inert");
    process.exitCode = 1;
  } else if (action === "kill-on") {
    autonomy.setAutonomyKillSwitch(killPath, true);
    console.log("Pi autonomy kill switch enabled; existing durable work remains reconcilable.");
  } else {
    autonomy.setAutonomyKillSwitch(killPath, false);
    console.log("Pi autonomy kill switch removed; valid local activation may resume new claims.");
  }
} else if (action === "eval") {
  const corpusPath = process.env.FM_AUTONOMY_EVAL_CORPUS || join(root, "tests", "fixtures", "fm-autonomy-heldout.json");
  const recordedOutputsPath = process.env.FM_AUTONOMY_EVAL_RECORDED || join(root, "tests", "fixtures", "fm-autonomy-recorded-outputs.json");
  const baselinePath = process.env.FM_AUTONOMY_EVAL_BASELINE || join(root, "tests", "fixtures", "fm-autonomy-baseline.json");
  const corpus = JSON.parse(readFileSync(corpusPath, "utf8"));
  const recordedOutputs = JSON.parse(readFileSync(recordedOutputsPath, "utf8"));
  const baseline = JSON.parse(readFileSync(baselinePath, "utf8"));
  const evaluation = autonomy.evaluateHeldOutRecordedOutputs(corpus.cases, recordedOutputs.outputs);
  const prompt = execFileSync("bash", [join(root, "bin", "fm-autonomy-prompt.sh")]);
  const promptSha256 = createHash("sha256").update(prompt).digest("hex");
  const corpusSha256 = createHash("sha256").update(readFileSync(corpusPath)).digest("hex");
  const recordedOutputsSha256 = createHash("sha256").update(readFileSync(recordedOutputsPath)).digest("hex");
  const provenance = recordedOutputs.provenance ?? {};
  const captureRecords = Array.isArray(provenance.records) ? provenance.records : [];
  const captureRecordsValid = corpus.cases.every((testCase) => {
    const output = recordedOutputs.outputs.find((candidate) => candidate.caseId === testCase.id);
    const record = captureRecords.find((candidate) => candidate.caseId === testCase.id);
    if (!output || !record) return false;
    const batch = autonomy.heldOutBatch(testCase);
    return record.batchId === batch.id &&
      record.inputSha256 === createHash("sha256").update(autonomy.canonicalJson(batch)).digest("hex") &&
      record.outputSha256 === createHash("sha256").update(autonomy.canonicalJson(output.decision)).digest("hex");
  });
  const requiredCasesPresent = baseline.requiredDisconfirmingCases.every(
    (id) => corpus.cases.some((testCase) => testCase.id === id && testCase.disconfirming),
  );
  const accepted = evaluation.failed === baseline.failed &&
    evaluation.passed === baseline.passed &&
    evaluation.contractFingerprint === baseline.contractFingerprint &&
    autonomy.AUTONOMY_DECISION_CONTRACT_VERSION === baseline.decisionContractVersion &&
    autonomy.AUTONOMY_MODEL_POLICY === baseline.modelPolicy &&
    promptSha256 === baseline.promptSha256 &&
    corpusSha256 === baseline.corpusSha256 &&
    corpus.cases.length === baseline.cases &&
    recordedOutputs.outputs.length === baseline.cases &&
    recordedOutputsSha256 === baseline.recordedOutputsSha256 &&
    provenance.captureInterface === baseline.captureProvenance?.interface &&
    provenance.captureMode === baseline.captureProvenance?.mode &&
    provenance.provider === baseline.captureProvenance?.provider &&
    provenance.model === baseline.captureProvenance?.model &&
    provenance.runtime === baseline.captureProvenance?.runtime &&
    provenance.runId === baseline.captureProvenance?.runId &&
    provenance.corpusSha256 === corpusSha256 &&
    provenance.contractFingerprint === evaluation.contractFingerprint &&
    provenance.promptSha256 === promptSha256 &&
    provenance.caseCount === corpus.cases.length &&
    captureRecords.length === corpus.cases.length && captureRecordsValid &&
    requiredCasesPresent;
  console.log(JSON.stringify({ ...evaluation, promptSha256, corpusSha256, recordedOutputsSha256, captureRecordsValid, accepted }));
  if (!accepted) process.exitCode = 1;
} else {
  const resolution = autonomy.loadAutonomyConfiguration(configPath, killPath, process.env);
  if (!resolution.config) {
    console.log(JSON.stringify({
      schema: autonomy.AUTONOMY_SCHEMA,
      configured: resolution.configured,
      active: false,
      killed: resolution.killed,
      diagnostics: resolution.diagnostics,
      contractFingerprint: autonomy.decisionContractFingerprint(),
    }));
    if (action === "doctor") process.exitCode = 1;
  } else {
    const firstmate = new autonomy.ShellFirstmateAdapter({
      fmRoot: root,
      fmHome: home,
      state,
      data,
      projects,
      redactedEnvNames: [resolution.config.linear.credential.env],
    });
    const diagnostics = [...resolution.diagnostics, ...firstmate.doctor(resolution.config)];
    const piPackage = process.env.FM_AUTONOMY_PI_PACKAGE;
    const linearCredentialName = resolution.config.linear.credential.env;
    const linearCredential = process.env[linearCredentialName] ?? "";
    if (process.env[linearCredentialName] === linearCredential) delete process.env[linearCredentialName];
    try {
      const piEntry = join(piPackage, "dist", "index.js");
      if (!existsSync(piEntry)) throw new Error("installed Pi package is unavailable");
      const { ModelRuntime } = await import(pathToFileURL(piEntry).href);
      const signal = AbortSignal.timeout(Math.min(resolution.config.supervision.limits.maxTurnMilliseconds, 15000));
      const runtime = await ModelRuntime.create({ allowModelNetwork: false, signal });
      const available = await runtime.getAvailable(resolution.config.supervision.model.provider, { signal });
      const selected = available.find((model) => model.id === resolution.config.supervision.model.id);
      const resolvedModelAuth = selected ? await runtime.getAuth(selected, { signal }) : undefined;
      if (resolvedModelAuth && containsCredential(resolvedModelAuth, linearCredential)) {
        diagnostics.push("configured Linear credential collides with the selected model provider authentication; use separate credentials and dedicated environment names");
      } else if (!selected) {
        diagnostics.push(
          `configured supervision model ${resolution.config.supervision.model.provider}/${resolution.config.supervision.model.id} is unavailable or lacks Pi authentication`,
        );
      } else if (!resolvedModelAuth) {
        diagnostics.push(`configured supervision model ${resolution.config.supervision.model.provider}/${resolution.config.supervision.model.id} lost authentication during doctor`);
      } else if (resolution.config.supervision.limits.maxPromptInputTokens + resolution.config.supervision.limits.maxOutputTokens > selected.contextWindow) {
        diagnostics.push(
          `configured supervision input/output ceilings exceed the selected model context window (${resolution.config.supervision.limits.maxPromptInputTokens + resolution.config.supervision.limits.maxOutputTokens} > ${selected.contextWindow})`,
        );
      }
    } catch (error) {
      const detail = (error instanceof Error ? error.message : String(error)).replaceAll(linearCredential, "[redacted]");
      diagnostics.push(`Pi model doctor failed: ${detail}`);
    } finally {
      if (linearCredential && process.env[linearCredentialName] === undefined) process.env[linearCredentialName] = linearCredential;
    }
    const journalPath = join(state, "autonomy", "journal.jsonl");
    let journal;
    let runtimeActive = resolution.active && !resolution.killed && diagnostics.length === 0;
    if (existsSync(journalPath)) {
      try {
        const runtimeResolution = { ...resolution, active: runtimeActive, diagnostics: [...new Set(diagnostics)] };
        const runtimeStatus = new autonomy.AutonomyOrchestrator({
          resolution: runtimeResolution,
          journal: new autonomy.DurableJournal(journalPath),
          killSwitchPath: killPath,
        }).reportStatus();
        journal = runtimeStatus.journal;
        runtimeActive = runtimeStatus.active;
        diagnostics.splice(0, diagnostics.length, ...runtimeStatus.diagnostics);
      } catch (error) {
        runtimeActive = false;
        diagnostics.push(`autonomy journal could not be read safely: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    const status = {
      schema: autonomy.AUTONOMY_SCHEMA,
      configured: true,
      active: runtimeActive,
      killed: resolution.killed,
      credentialPresent: resolution.credentialPresent,
      diagnostics: [...new Set(diagnostics)],
      journal,
      contractFingerprint: autonomy.decisionContractFingerprint(),
    };
    console.log(JSON.stringify(status));
    if (action === "doctor" && !status.active) process.exitCode = 1;
  }
}
NODE
