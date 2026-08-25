#!/usr/bin/env bash
# Executable-interface regression for the deep Pi autonomy orchestration module.
# It exercises only exported behavior with fixture-backed Linear and held-out
# inputs; no live Linear workspace, forge, project, worker, or credential is
# touched.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi autonomy tests"; exit 0; }
NODE_MAJOR=$(node -p 'Number(process.versions.node.split(".")[0])')
[ "$NODE_MAJOR" -ge 22 ] || { echo "skip: Node 22 is required by the installed Pi SDK"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-autonomy-core)
MODULE="$ROOT/.pi/extensions/lib/fm-autonomy.ts" \
CORPUS="$ROOT/tests/fixtures/fm-autonomy-heldout.json" \
BASELINE="$ROOT/tests/fixtures/fm-autonomy-baseline.json" \
RECORDED="$ROOT/tests/fixtures/fm-autonomy-recorded-outputs.json" \
LINEAR_FIXTURE="$ROOT/tests/fixtures/fm-linear-api.json" \
PROMPT_SCRIPT="$ROOT/bin/fm-autonomy-prompt.sh" \
TMP_ROOT="$TMP_ROOT" \
node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const m = await import(pathToFileURL(process.env.MODULE).href);
const temp = process.env.TMP_ROOT;
const corpusEnvelope = JSON.parse(readFileSync(process.env.CORPUS, "utf8"));
const baseline = JSON.parse(readFileSync(process.env.BASELINE, "utf8"));
const recordedOutputs = JSON.parse(readFileSync(process.env.RECORDED, "utf8"));
const linearFixture = JSON.parse(readFileSync(process.env.LINEAR_FIXTURE, "utf8"));

const limits = {
  maxBatchEvents: 10,
  maxBatchIssues: 10,
  maxPromptInputTokens: 10000,
  maxOutputTokens: 1000,
  maxTurnMilliseconds: 5000,
  maxIterationsPerBatch: 1,
  maxCostUsdPerWindow: 1,
  costWindowSeconds: 3600,
  maxLinearPages: 4,
  maxLinearRetries: 2,
  maxLinearRetryMilliseconds: 1000,
};
const configObject = {
  version: 1,
  enabled: true,
  ownerId: "firstmate-test",
  pollSeconds: 60,
  linear: {
    workspaceId: "workspace-1",
    credential: { env: "FM_TEST_LINEAR_KEY", kind: "api-key" },
    scopes: [{
      teamId: "team-1",
      projectId: "project-1",
      statuses: {
        intake: ["status-todo"],
        claimed: "status-claimed",
        inProgress: "status-progress",
        completed: "status-complete",
      },
      labels: { required: ["label-auto"], blocked: ["label-blocked"] },
    }],
  },
  repositories: [{ linearProjectId: "project-1", firstmateProject: "app", checkout: "app" }],
  supervision: {
    model: { provider: "test-provider", id: "cheap-model", thinkingLevel: "low" },
    limits,
  },
  capacity: { maxActiveIssues: 4, maxParallelWorkers: 3, maxHeavyValidations: 1 },
};
const env = { FM_TEST_LINEAR_KEY: "secret-fixture-token" };
const resolution = m.validateAutonomyConfig(configObject, env);
assert.equal(resolution.active, true, resolution.diagnostics.join("; "));
assert.equal(JSON.stringify(resolution).includes("secret-fixture-token"), false, "credential leaked into config resolution");
const missingCredential = m.validateAutonomyConfig(configObject, {});
assert.equal(missingCredential.active, false);
assert.equal(missingCredential.valid, true);
assert(missingCredential.diagnostics.some((line) => line.includes("environment variable FM_TEST_LINEAR_KEY is required")));

const malformed = structuredClone(configObject);
malformed.repositories = [];
const malformedResolution = m.validateAutonomyConfig(malformed, env);
assert.equal(malformedResolution.active, false);
assert(malformedResolution.diagnostics.some((line) => line.includes("config.repositories must contain")));
assert(malformedResolution.diagnostics.some((line) => line.includes("must have exactly one")));

const shellHome = join(temp, "shell-adapter");
mkdirSync(join(shellHome, "state"), { recursive: true });
mkdirSync(join(shellHome, "data"), { recursive: true });
mkdirSync(join(shellHome, "projects", "app"), { recursive: true });
writeFileSync(join(shellHome, "data", "projects.md"), "- app [no-mistakes +yolo] - fixture (added 2026-08-25)\n");
const subprocessCredentials = [];
const shellAdapter = new m.ShellFirstmateAdapter({
  fmRoot: process.cwd(),
  fmHome: shellHome,
  state: join(shellHome, "state"),
  data: join(shellHome, "data"),
  projects: join(shellHome, "projects"),
  env: { FM_TEST_LINEAR_KEY: env.FM_TEST_LINEAR_KEY },
  redactedEnvNames: ["FM_TEST_LINEAR_KEY"],
  exec: (_command, args, options) => {
    subprocessCredentials.push(options.env.FM_TEST_LINEAR_KEY);
    if (args.includes("--raw")) return "no-mistakes on\n";
    if (args.some((arg) => String(arg).endsWith("fm-project-mode.sh"))) return "no-mistakes on\n";
    if (args[0] === "-C" && args.includes("--show-toplevel")) return join(shellHome, "projects", "app");
    if (args[0] === "-C" && args.includes("get-url")) return "https://github.com/acme/app.git";
    return "/fixture/bin\n";
  },
});
assert.deepEqual(shellAdapter.doctor(resolution.config), []);
assert(subprocessCredentials.length > 0);
assert(subprocessCredentials.every((value) => value === undefined), "Linear credential propagated to a Firstmate subprocess");

// Held-out routing/collision baseline, including disconfirming cases.
const evaluation = m.evaluateHeldOutRecordedOutputs(corpusEnvelope.cases, recordedOutputs.outputs);
assert.equal(evaluation.failed, 0, JSON.stringify(evaluation, null, 2));
const classifierEvaluation = await m.evaluateHeldOutClassifier(corpusEnvelope.cases, {
  async classify(batch) {
    const caseId = batch.events[0].id.split(":").slice(1, -1).join(":");
    return structuredClone(recordedOutputs.outputs.find((candidate) => candidate.caseId === caseId).decision);
  },
});
assert.equal(classifierEvaluation.failed, 0, JSON.stringify(classifierEvaluation, null, 2));
const oracleDrift = structuredClone(corpusEnvelope.cases);
oracleDrift[0].routing.expectedAction = oracleDrift[0].routing.expectedAction === "wake" ? "nextTurn" : "wake";
assert.equal(m.evaluateHeldOutRecordedOutputs(oracleDrift, recordedOutputs.outputs).failed, 1, "recorded classifier outputs were derived from changed expectations");
assert.equal(evaluation.passed, baseline.passed);
assert.equal(evaluation.contractFingerprint, baseline.contractFingerprint);
assert.equal(m.AUTONOMY_DECISION_CONTRACT_VERSION, baseline.decisionContractVersion);
const prompt = execFileSync("bash", [process.env.PROMPT_SCRIPT]);
assert.equal(createHash("sha256").update(prompt).digest("hex"), baseline.promptSha256);
assert.equal(createHash("sha256").update(readFileSync(process.env.RECORDED)).digest("hex"), baseline.recordedOutputsSha256);
for (const id of baseline.requiredDisconfirmingCases) {
  const found = corpusEnvelope.cases.find((item) => item.id === id);
  assert(found?.disconfirming, `required disconfirming case ${id} is absent`);
}

// Linear pagination, bounded rate-limit retry, local label filtering, official
// auth header shape, dependency direction, and GraphQL error refusal.
const responseFrom = (fixture) => new Response(JSON.stringify(fixture.body), {
  status: fixture.status,
  headers: fixture.headers ?? { "Content-Type": "application/json" },
});
const responseQueue = [
  linearFixture.responses.rateLimited,
  linearFixture.responses.page1,
  linearFixture.responses.page2,
];
const requests = [];
const sleeps = [];
const fakeClock = {
  now: () => new Date("2026-08-25T00:00:00.000Z"),
  sleep: async (ms) => { sleeps.push(ms); },
};
const client = new m.LinearGraphqlClient({
  token: env.FM_TEST_LINEAR_KEY,
  credentialKind: "api-key",
  limits,
  clock: fakeClock,
  fetchImpl: async (_url, options) => {
    requests.push(options);
    return responseFrom(responseQueue.shift());
  },
});
const issues = await client.listEligibleIssues(resolution.config);
assert.deepEqual(issues.map((issue) => issue.id), ["issue-1", "issue-2"]);
shellAdapter.assertPullRequestRepository(resolution.config, issues[0], "https://github.com/acme/app/pull/99");
assert.throws(
  () => shellAdapter.assertPullRequestRepository(resolution.config, issues[0], "https://github.com/acme/other/pull/99"),
  (error) => error.code === "pr-repository-mismatch",
);
writeFileSync(join(shellHome, "data", "secondmates.md"), "- builder - routed work (home: /fixture; scope: unrelated billing reports; projects: app; added 2026-08-25)\n");
shellAdapter.assertProjectOwnership(resolution.config, issues[0]);
assert.deepEqual(shellAdapter.doctor(resolution.config), [], "non-exclusive secondmate clone membership disabled primary autonomy");
writeFileSync(join(shellHome, "data", "secondmates.md"), "- builder - routed work (home: /fixture; scope: change src one ts; projects: app; added 2026-08-25)\n");
assert.throws(() => shellAdapter.assertProjectOwnership(resolution.config, issues[0]), (error) => error.code === "secondmate-route");
rmSync(join(shellHome, "data", "secondmates.md"));
assert.deepEqual(issues[1].blockedByIssueIds, ["issue-1"]);
const priorityPage = structuredClone(linearFixture.responses.page1);
priorityPage.body.data.issues.nodes = [
  { ...structuredClone(linearFixture.responses.page1.body.data.issues.nodes[0]), priority: 0 },
  { ...structuredClone(linearFixture.responses.page2.body.data.issues.nodes[0]), priority: 1, inverseRelations: { nodes: [] } },
];
priorityPage.body.data.issues.pageInfo = { hasNextPage: false, endCursor: null };
const priorityClient = new m.LinearGraphqlClient({
  token: "priority-not-logged",
  credentialKind: "api-key",
  limits,
  fetchImpl: async () => responseFrom(priorityPage),
});
assert.deepEqual((await priorityClient.listEligibleIssues(resolution.config)).map((issue) => issue.id), ["issue-2", "issue-1"]);
const secretPage = structuredClone(linearFixture.responses.page1);
secretPage.body.data.issues.nodes[0].description = `Leaked ${env.FM_TEST_LINEAR_KEY} and ghp_fixturecredential123456789`;
secretPage.body.data.issues.pageInfo = { hasNextPage: false, endCursor: null };
const secretClient = new m.LinearGraphqlClient({
  token: env.FM_TEST_LINEAR_KEY,
  credentialKind: "api-key",
  limits,
  fetchImpl: async () => responseFrom(secretPage),
});
const redactedIssue = (await secretClient.listEligibleIssues(resolution.config))[0];
assert.equal(redactedIssue.description.includes(env.FM_TEST_LINEAR_KEY), false);
assert.equal(redactedIssue.description.includes("ghp_fixturecredential"), false);
assert.equal(requests.length, 3);
assert.equal(requests[0].headers.Authorization, env.FM_TEST_LINEAR_KEY);
assert.equal(String(requests[0].headers.Authorization).startsWith("Bearer "), false);
assert.equal(sleeps.length, 1);
const pageBodies = requests.slice(1).map((request) => JSON.parse(request.body));
assert.equal(pageBodies[0].variables.after, null);
assert.equal(pageBodies[1].variables.after, "cursor-1");
assert.equal(JSON.stringify(requests).includes(env.FM_TEST_LINEAR_KEY), true, "fixture did not exercise auth header");

let oauthAuthorization = "";
const errorClient = new m.LinearGraphqlClient({
  token: "not-logged",
  credentialKind: "oauth",
  limits: { ...limits, maxLinearRetries: 0 },
  fetchImpl: async (_url, options) => {
    oauthAuthorization = options.headers.Authorization;
    return responseFrom(linearFixture.responses.graphqlError);
  },
});
await assert.rejects(() => errorClient.listEligibleIssues(resolution.config), (error) => error.code === "linear-graphql" && !error.message.includes("not-logged"));
assert.equal(oauthAuthorization, "Bearer not-logged");
const networkSecret = "network-secret-not-logged";
const networkErrorClient = new m.LinearGraphqlClient({
  token: networkSecret,
  credentialKind: "api-key",
  limits: { ...limits, maxLinearRetries: 0 },
  fetchImpl: async () => { throw new Error(`transport accidentally echoed ${networkSecret}`); },
});
await assert.rejects(() => networkErrorClient.listEligibleIssues(resolution.config), (error) => error.code === "linear-network" && !error.message.includes(networkSecret) && error.message.includes("[redacted]"));
const wrongWorkspaceClient = new m.LinearGraphqlClient({
  token: "not-logged",
  credentialKind: "api-key",
  limits,
  fetchImpl: async () => responseFrom(linearFixture.responses.wrongWorkspace),
});
await assert.rejects(() => wrongWorkspaceClient.listEligibleIssues(resolution.config), (error) => error.code === "linear-workspace-refused");

const claimIssueRaw = structuredClone(linearFixture.responses.page1.body.data.issues.nodes[0]);
const remoteClaim = { stateId: "status-todo", comments: [] };
const claimOperations = [];
const claimRequests = [];
const claimClient = new m.LinearGraphqlClient({
  token: "claim-secret-not-logged",
  credentialKind: "api-key",
  limits,
  fetchImpl: async (_url, options) => {
    const body = JSON.parse(options.body);
    claimOperations.push(body.operationName);
    claimRequests.push(body);
    if (body.operationName === "FirstmateIssueClaimRead") {
      const issue = structuredClone(claimIssueRaw);
      issue.state = { id: remoteClaim.stateId };
      return new Response(JSON.stringify({ data: { organization: { id: "workspace-1" }, issue } }), { status: 200 });
    }
    if (body.operationName === "FirstmateCommentEvidence") {
      return new Response(JSON.stringify({ data: { organization: { id: "workspace-1" }, issue: { comments: { nodes: remoteClaim.comments.map((value) => ({ body: value })), pageInfo: { hasNextPage: false } } } } }), { status: 200 });
    }
    if (body.operationName === "FirstmateCommentCreate") {
      remoteClaim.comments.push(body.variables.input.body);
      return new Response(JSON.stringify({ data: { commentCreate: { success: true } } }), { status: 200 });
    }
    if (body.operationName === "FirstmateIssueUpdate") {
      remoteClaim.stateId = body.variables.input.stateId;
      return new Response(JSON.stringify({ data: { issueUpdate: { success: true } } }), { status: 200 });
    }
    if (body.operationName === "FirstmateClaimSnapshot") {
      const issue = structuredClone(claimIssueRaw);
      issue.state = { id: remoteClaim.stateId };
      issue.comments = { nodes: remoteClaim.comments.map((value) => ({ body: value })), pageInfo: { hasNextPage: false } };
      return new Response(JSON.stringify({ data: { organization: { id: "workspace-1" }, issue } }), { status: 200 });
    }
    if (body.operationName === "FirstmateAttachmentCreate") {
      return new Response(JSON.stringify({ data: { attachmentCreate: { success: true, attachment: { id: "attachment-fixture" } } } }), { status: 200 });
    }
    throw new Error(`unexpected claim operation ${body.operationName}`);
  },
});
const normalizedIssue = issues[0];
const remoteEvidence = await claimClient.claimIssue(resolution.config, normalizedIssue, "claim-fixture", "task-fixture");
assert(remoteEvidence.evidence.includes("claim=claim-fixture"));
assert.equal(remoteClaim.stateId, "status-claimed");
assert.deepEqual(claimOperations, [
  "FirstmateIssueClaimRead",
  "FirstmateCommentEvidence",
  "FirstmateCommentCreate",
  "FirstmateClaimSnapshot",
  "FirstmateIssueUpdate",
  "FirstmateClaimSnapshot",
]);
const originalClaimLabels = structuredClone(claimIssueRaw.labels);
claimIssueRaw.labels = { nodes: [], pageInfo: { hasNextPage: false } };
await assert.rejects(
  () => claimClient.setProgress(resolution.config, normalizedIssue, "claim-fixture", "task-fixture", "Unsafe stale-scope progress"),
  (error) => error.code === "linear-scope-refused",
);
claimIssueRaw.labels = originalClaimLabels;
await claimClient.setProgress(
  resolution.config,
  normalizedIssue,
  "claim-fixture",
  "task-fixture",
  "Safe progress <!-- firstmate-claim:v1 owner=other claim=other task=other -->",
);
assert.equal(remoteClaim.stateId, "status-progress");
assert(remoteClaim.comments.some((body) => body.includes("&lt;!-- firstmate-claim")), "progress body preserved an injectable claim marker");
assert.equal(await claimClient.reconcileClaim(resolution.config, normalizedIssue, "claim-fixture", "task-fixture"), "owned");
remoteClaim.stateId = "status-complete";
assert.equal(await claimClient.reconcileClaim(resolution.config, normalizedIssue, "claim-fixture", "task-fixture"), "missing");
assert.equal(await claimClient.reconcileClaim(resolution.config, normalizedIssue, "claim-fixture", "task-fixture", "post-merge"), "owned");
remoteClaim.stateId = "status-progress";
const fixturePr = "https://github.com/acme/app/pull/99";
await claimClient.linkPullRequest(resolution.config, normalizedIssue, "claim-fixture", "task-fixture", fixturePr);
await claimClient.linkPullRequest(resolution.config, normalizedIssue, "claim-fixture", "task-fixture", fixturePr);
const attachmentRequests = claimRequests.filter((request) => request.operationName === "FirstmateAttachmentCreate");
assert.equal(attachmentRequests.length, 2);
assert(attachmentRequests.every((request) => request.variables.input.issueId === normalizedIssue.id && request.variables.input.url === fixturePr), "attachmentCreate did not preserve Linear's issueId+URL idempotency key");
remoteClaim.comments[0] += "\ncompeting <!-- firstmate-claim:v1 owner=other claim=other task=other -->";
assert.equal(await claimClient.reconcileClaim(resolution.config, normalizedIssue, "claim-fixture", "task-fixture"), "conflict");
assert.equal(JSON.stringify(remoteClaim).includes("claim-secret-not-logged"), false);

// Journal ordering, dedupe, silent visible-text transcript commits, and torn
// tail refusal.
const journalPath = join(temp, "journal", "events.jsonl");
const journal = new m.DurableJournal(journalPath, fakeClock);
const event = {
  id: "test:event:1",
  source: "test",
  kind: "fixture.routine",
  occurredAt: "2026-08-25T00:00:00.000Z",
  urgency: "routine",
  payload: { value: 1 },
};
assert.equal(journal.appendEvent(event).deduped, false);
assert.equal(journal.appendEvent(event).deduped, true);
journal.appendTranscript({
  id: "transcript-1",
  session: "main-session",
  entryId: "entry-user",
  role: "user",
  text: "Visible captain text",
  committedAt: "2026-08-25T00:00:01.000Z",
});
journal.appendTranscript({
  id: "transcript-2",
  session: "main-session",
  entryId: "entry-assistant",
  role: "assistant",
  text: "Visible assistant text only",
  committedAt: "2026-08-25T00:00:02.000Z",
});
assert.deepEqual(journal.read().map((record) => record.kind), ["event", "transcript", "transcript"]);
assert.equal(readFileSync(journalPath, "utf8").includes("toolResult"), false);
const tornPath = join(temp, "journal", "torn.jsonl");
writeFileSync(tornPath, '{"schema":"fm-autonomy-journal.v1"');
assert.throws(() => new m.DurableJournal(tornPath).read(), (error) => error.code === "journal-torn");
const journalTarget = join(temp, "journal", "target.jsonl");
const journalLink = join(temp, "journal", "linked.jsonl");
writeFileSync(journalTarget, "");
symlinkSync(journalTarget, journalLink);
assert.throws(() => new m.DurableJournal(journalLink).appendEvent({ ...event, id: "test:event:linked" }), (error) => error.code === "journal-unsafe");
assert.equal(readFileSync(journalTarget, "utf8"), "");

const claimFor = (issueId, identifier, file, overrides = {}) => ({
  issueId,
  issueIdentifier: identifier,
  repository: "app",
  dependencies: [],
  predictedFiles: [file],
  predictedGlobs: [],
  predictedSymbols: [],
  migrationOrSchema: false,
  sharedExternalResources: [],
  semanticCoupling: [`semantic-${identifier}`],
  evidence: [`The fixture names ${file}.`],
  validation: "light",
  surface: "product",
  boundaries: {
    destructive: false,
    irreversible: false,
    production: false,
    migration: false,
    release: false,
    credentials: false,
    securitySensitive: false,
    ambiguous: false,
    redValidation: false,
  },
  ...overrides,
});
const batchFor = (eventValue) => ({
  id: m.stableId("batch", [eventValue.id]),
  events: [eventValue],
  issueCount: eventValue.kind === "linear.issue.available" ? 1 : 0,
  estimatedInputTokens: 20,
});

// Structured-decision validation refuses missing claims and urgent coalescing.
const urgentIssueEvent = {
  id: "linear:workspace-1:issue-1:2026-08-25T01:00:00.000Z",
  source: "linear",
  kind: "linear.issue.available",
  occurredAt: "2026-08-25T01:00:00.000Z",
  urgency: "urgent",
  payload: { issueId: "issue-1" },
};
const urgentBatch = batchFor(urgentIssueEvent);
const invalidDecision = m.createDecision({
  batchId: urgentBatch.id,
  action: "coalesce",
  eventIds: [urgentIssueEvent.id],
  summary: "wrong",
  reasonCodes: ["duplicate"],
  workClaims: [],
});
assert.throws(() => m.validateDecision(invalidDecision, urgentBatch), (error) => error.code === "decision-invalid");
const validDecision = m.createDecision({
  batchId: urgentBatch.id,
  action: "wake",
  eventIds: [urgentIssueEvent.id],
  summary: "Inspect ENG-1.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-1", "ENG-1", "src/one.ts")],
});
assert.equal(m.validateDecision(validDecision, urgentBatch).id, validDecision.id);

// Routine nextTurn, urgent idle wake, working steer, delivery evidence, crash
// replay, and exactly-once suppression.
class FakeDelivery {
  constructor({ idle, generation, persist = false }) {
    this.idle = idle;
    this.generation = generation;
    this.persist = persist;
    this.delivered = new Set();
    this.calls = [];
  }
  isMainIdle() { return this.idle; }
  sessionId() { return "main-session"; }
  processGeneration() { return this.generation; }
  hasDelivered(id) { return this.delivered.has(id); }
  async deliver(decision, mode) {
    this.calls.push({ id: decision.id, mode });
    if (this.persist) this.delivered.add(decision.id);
    return { accepted: true, evidence: "accepted", sessionId: this.sessionId(), processGeneration: this.generation };
  }
}
const deliveryJournal = new m.DurableJournal(join(temp, "delivery", "journal.jsonl"), fakeClock);
const routineEvent = { ...event, id: "test:event:routine-merge" };
deliveryJournal.appendEvent(routineEvent);
const routineBatch = batchFor(routineEvent);
const routineDecision = m.createDecision({
  batchId: routineBatch.id,
  action: "nextTurn",
  eventIds: [routineEvent.id],
  summary: "Routine context.",
  reasonCodes: ["routine"],
  workClaims: [],
});
deliveryJournal.append("decision", routineDecision.id, routineDecision, `decision:${routineDecision.id}`);
const nextDelivery = new FakeDelivery({ idle: true, generation: "process-a", persist: true });
const nextOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: deliveryJournal, delivery: nextDelivery, killSwitchPath: join(temp, "delivery", "KILL") });
assert.equal(await nextOrchestrator.deliverDecision(routineDecision), "nextTurn");
assert.deepEqual(nextDelivery.calls.map((call) => call.mode), ["nextTurn"]);
await nextOrchestrator.reconcile();
assert.equal(nextDelivery.calls.length, 1, "acknowledged routine delivery duplicated");

const urgentJournal = new m.DurableJournal(join(temp, "urgent", "journal.jsonl"), fakeClock);
urgentJournal.appendEvent(urgentIssueEvent);
urgentJournal.append("decision", validDecision.id, validDecision, `decision:${validDecision.id}`);
const idleDelivery = new FakeDelivery({ idle: true, generation: "process-a", persist: true });
const idleOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: urgentJournal, delivery: idleDelivery, killSwitchPath: join(temp, "urgent", "KILL") });
assert.equal(await idleOrchestrator.deliverDecision(validDecision), "wake-idle");
assert.deepEqual(idleDelivery.calls.map((call) => call.mode), ["wake-idle"]);
await idleOrchestrator.reconcile();
assert.equal(idleDelivery.calls.length, 1, "urgent idle wake duplicated");

const steerJournal = new m.DurableJournal(join(temp, "steer", "journal.jsonl"), fakeClock);
steerJournal.appendEvent({ ...urgentIssueEvent, id: "linear:workspace-1:issue-steer:2026-08-25T01:00:00.000Z", payload: { issueId: "issue-steer" } });
const steerEvent = steerJournal.pendingEvents(1)[0];
const steerBatch = batchFor(steerEvent);
const steerDecision = m.createDecision({
  batchId: steerBatch.id,
  action: "wake",
  eventIds: [steerEvent.id],
  summary: "Steer at the safe boundary.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-steer", "ENG-STEER", "src/steer.ts")],
});
steerJournal.append("decision", steerDecision.id, steerDecision, `decision:${steerDecision.id}`);
const workingDelivery = new FakeDelivery({ idle: false, generation: "process-a", persist: true });
const steerOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: steerJournal, delivery: workingDelivery, killSwitchPath: join(temp, "steer", "KILL") });
assert.equal(await steerOrchestrator.deliverDecision(steerDecision), "steer-working");
assert.deepEqual(workingDelivery.calls.map((call) => call.mode), ["steer-working"]);

const replayJournal = new m.DurableJournal(join(temp, "replay", "journal.jsonl"), fakeClock);
replayJournal.appendEvent(routineEvent);
replayJournal.append("decision", routineDecision.id, routineDecision, `decision:${routineDecision.id}`);
const lostQueue = new FakeDelivery({ idle: true, generation: "process-before-crash", persist: false });
const beforeCrash = new m.AutonomyOrchestrator({ resolution, journal: replayJournal, delivery: lostQueue, killSwitchPath: join(temp, "replay", "KILL") });
await beforeCrash.deliverDecision(routineDecision);
assert.equal(lostQueue.calls.length, 1);
const replacement = new FakeDelivery({ idle: true, generation: "process-after-crash", persist: true });
const afterCrash = new m.AutonomyOrchestrator({ resolution, journal: replayJournal, delivery: replacement, killSwitchPath: join(temp, "replay", "KILL") });
await afterCrash.reconcile();
assert.equal(replacement.calls.length, 1, "unacknowledged nextTurn decision did not replay after replacement");
assert.equal(replayJournal.deliveryAcknowledged(routineDecision.id), true);

const costJournal = new m.DurableJournal(join(temp, "cost", "journal.jsonl"), fakeClock);
costJournal.appendEvent({ ...routineEvent, id: "test:cost-window:1" });
costJournal.append("usage", "cost-prior", { provider: "fixture", model: "cheap", input: 1, output: 1, cacheRead: 0, cacheWrite: 0, costUsd: 0.99 }, "usage:cost-prior");
let classifiedOverBudget = false;
const costOrchestrator = new m.AutonomyOrchestrator({
  resolution,
  journal: costJournal,
  classifier: { async classify() { classifiedOverBudget = true; return routineDecision; } },
  classificationCostEstimator: () => 0.02,
  clock: fakeClock,
  killSwitchPath: join(temp, "cost", "KILL"),
});
await assert.rejects(() => costOrchestrator.classifyPendingBatch(), (error) => error.code === "cost-ceiling");
assert.equal(classifiedOverBudget, false, "over-budget batch reached the model");
assert.equal(costJournal.pendingEvents(10).length, 1, "cost refusal consumed the original event instead of preserving it for retry");

// Claim idempotency, dispatch through the adapter seam, restart
// reconciliation, kill-switch behavior, stronger-boundary refusal, and
// green-merge-before-Linear-close ordering.
const operationLog = [];
const claimed = new Set();
const tasks = new Set();
const taskPrs = new Map();
let redLanding = false;
let capacityBlocked = false;
const mergedHeads = new Map();
const remoteDependencies = new Map();
const remoteStates = new Map();
let completeDuringPrepare = false;
let claimPause;
let resumeClaim;
let getIssuePause;
let resumeGetIssue;
const linearMock = {
  async listEligibleIssues() { return []; },
  async getIssue(_config, issueId) {
    if (getIssuePause && issueId === "issue-1") await getIssuePause;
    const source = issueId === "issue-1" ? issueEvent.payload : issueId === "issue-2" ? secondEvent?.payload ?? issueEvent.payload : issueEvent.payload;
    return {
      id: issueId,
      identifier: String(source.identifier).replace(/\d+$/, issueId.replace(/\D/g, "") || "1"),
      title: source.title,
      description: source.description,
      priority: 1,
      createdAt: "2026-08-25T01:00:00.000Z",
      updatedAt: "2026-08-25T01:00:00.000Z",
      url: source.url,
      teamId: "team-1",
      projectId: "project-1",
      stateId: remoteStates.get(issueId) ?? "status-todo",
      labelIds: ["label-auto"],
      blockedByIssueIds: remoteDependencies.get(issueId) ?? [],
      blocksIssueIds: [],
    };
  },
  async claimIssue(_config, issue, claimId, taskId) {
    operationLog.push(`claim:${issue.id}`);
    if (claimPause && issue.id === "issue-1") await claimPause;
    claimed.add(issue.id);
    remoteStates.set(issue.id, "status-claimed");
    return { evidence: `${claimId}:${taskId}` };
  },
  async setProgress(_config, issue) { operationLog.push(`progress:${issue.id}`); remoteStates.set(issue.id, "status-progress"); return { evidence: "progress" }; },
  async linkPullRequest(_config, issue) { operationLog.push(`link:${issue.id}`); return { evidence: "link" }; },
  async completeIssue(_config, issue) { operationLog.push(`complete:${issue.id}`); remoteStates.set(issue.id, "status-complete"); return { evidence: "complete" }; },
  async reconcileClaim(_config, issue, _claimId, _taskId, phase = "active") {
    operationLog.push(`reconcile:${issue.id}`);
    if (!claimed.has(issue.id)) return "missing";
    return remoteStates.get(issue.id) === "status-complete" && phase !== "post-merge" ? "missing" : "owned";
  },
};
const firstmateMock = {
  capacity() { return capacityBlocked ? { activeIssues: 1, activeWorkers: 1, activeHeavyValidations: 0 } : { activeIssues: 0, activeWorkers: 0, activeHeavyValidations: 0 }; },
  assertProjectOwnership() {},
  assertPullRequestRepository(_config, _issue, prUrl) {
    if (!prUrl.startsWith("https://github.com/acme/app/pull/")) throw new m.AutonomyError("pr-repository-mismatch", "fixture repository mismatch");
  },
  async dispatch(_config, issue, _claim, taskId) { operationLog.push(`dispatch:${issue.id}`); tasks.add(taskId); return { taskId, mode: "no-mistakes", evidence: `meta:${taskId}` }; },
  taskExists(taskId) { return tasks.has(taskId); },
  taskPullRequest(taskId) { return taskPrs.get(taskId); },
  async prepareLanding(_config, issue) {
    operationLog.push(`prepare:${issue.id}`);
    if (completeDuringPrepare) remoteStates.set(issue.id, "status-complete");
    return { expectedHead: "a".repeat(40), evidence: "prepared current green head" };
  },
  async verifyMerged(_config, issue, _taskId, _prUrl, expectedHead) {
    operationLog.push(`verify-merged:${issue.id}`);
    if (mergedHeads.get(issue.id) !== expectedHead) throw new m.AutonomyError("landing-unconfirmed", "fixture PR is still open");
    return { merged: true, green: true, currentHead: expectedHead, expectedHead, evidence: "reconciled merged head" };
  },
  async mergeAndVerify(_config, issue, _taskId, _prUrl, expectedHead) {
    operationLog.push(`merge:${issue.id}`);
    if (redLanding) return { merged: false, green: false, currentHead: "bad", expectedHead, evidence: "red" };
    mergedHeads.set(issue.id, expectedHead);
    return { merged: true, green: true, currentHead: expectedHead, expectedHead, evidence: "green current head" };
  },
  doctor() { return []; },
};
const claimsJournal = new m.DurableJournal(join(temp, "claims", "journal.jsonl"), fakeClock);
const issueEvent = {
  ...urgentIssueEvent,
  payload: {
    issueId: "issue-1",
    identifier: "ENG-1",
    title: "One",
    description: "Change src/one.ts",
    priority: 1,
    url: "https://linear.app/acme/issue/ENG-1/one",
    teamId: "team-1",
    projectId: "project-1",
    repository: "app",
    blockedByIssueIds: [],
    blocksIssueIds: [],
  },
};
claimsJournal.appendEvent(issueEvent);
const issueBatch = batchFor(issueEvent);
const issueDecision = m.createDecision({
  batchId: issueBatch.id,
  action: "wake",
  eventIds: [issueEvent.id],
  summary: "Dispatch ENG-1.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-1", "ENG-1", "src/one.ts")],
});
claimsJournal.append("decision", issueDecision.id, issueDecision, `decision:${issueDecision.id}`);
const killPath = join(temp, "claims", "KILL");
const claimOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: claimsJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: killPath });
claimPause = new Promise((resolve) => { resumeClaim = resolve; });
const firstDispatch = claimOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" });
while (!operationLog.includes("claim:issue-1")) await new Promise((resolve) => setTimeout(resolve, 0));
const competingOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: claimsJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: killPath });
await assert.rejects(
  () => competingOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" }),
  (error) => error.code === "issue-operation-busy" && error.retryable,
);
const concurrentLocalDispatch = claimOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" });
resumeClaim();
claimPause = undefined;
const [dispatched, concurrentDispatch] = await Promise.all([firstDispatch, concurrentLocalDispatch]);
assert.equal(concurrentDispatch.taskId, dispatched.taskId);
assert.equal(operationLog.filter((entry) => entry === "claim:issue-1").length, 1, "concurrent dispatch duplicated the Linear claim");
assert.equal(operationLog.filter((entry) => entry === "dispatch:issue-1").length, 1, "concurrent reconciliation duplicated Firstmate dispatch");
const firstLease = claimsJournal.read().find((record) => record.kind === "operation-lease-acquired" && record.key === "issue-1");
assert.equal(firstLease.data.fence, 1);
getIssuePause = new Promise((resolve) => { resumeGetIssue = resolve; });
const fencedDispatch = competingOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" });
while (claimsJournal.read().filter((record) => record.kind === "operation-lease-acquired" && record.key === "issue-1").length < 2) {
  await new Promise((resolve) => setTimeout(resolve, 0));
}
claimsJournal.append("operation-lease-released", "issue-1", {
  operationId: firstLease.data.operationId,
  owner: firstLease.data.owner,
  fence: firstLease.data.fence,
}, `stale-release:${firstLease.data.operationId}`);
const thirdOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: claimsJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: killPath });
await assert.rejects(
  () => thirdOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" }),
  (error) => error.code === "issue-operation-busy",
);
resumeGetIssue();
getIssuePause = undefined;
assert.equal((await fencedDispatch).taskId, dispatched.taskId);
assert(tasks.has(dispatched.taskId));
const beforeIdempotent = operationLog.length;
const dispatchedAgain = await claimOrchestrator.dispatchIssue(issueDecision.id, "issue-1", { harness: "pi" });
assert.equal(dispatchedAgain.taskId, dispatched.taskId);
assert.equal(operationLog.length, beforeIdempotent, "duplicate delivery reclaimed or redispatched one issue");

writeFileSync(killPath, "disabled\n");
await claimOrchestrator.reconcile();
assert(operationLog.includes("reconcile:issue-1"), "kill switch stopped reconciliation of existing work");
const secondEvent = {
  ...issueEvent,
  id: "linear:workspace-1:issue-2:2026-08-25T01:30:00.000Z",
  occurredAt: "2026-08-25T01:30:00.000Z",
  payload: { ...issueEvent.payload, issueId: "issue-2", identifier: "ENG-2", title: "Two", description: "Change src/two.ts", url: "https://linear.app/acme/issue/ENG-2/two" },
};
claimsJournal.appendEvent(secondEvent);
const secondBatch = batchFor(secondEvent);
const secondDecision = m.createDecision({
  batchId: secondBatch.id,
  action: "wake",
  eventIds: [secondEvent.id],
  summary: "Dispatch ENG-2.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-2", "ENG-2", "src/two.ts")],
});
claimsJournal.append("decision", secondDecision.id, secondDecision, `decision:${secondDecision.id}`);
await assert.rejects(() => claimOrchestrator.dispatchIssue(secondDecision.id, "issue-2", { harness: "pi" }), (error) => error.code === "autonomy-inactive");

// Existing owned work may still land while the kill switch prevents new work.
taskPrs.set(dispatched.taskId, "https://github.com/acme/app/pull/1");
await claimOrchestrator.linkPullRequest("issue-1", "https://github.com/acme/app/pull/1");
completeDuringPrepare = true;
const mergesBeforeCompletedStatus = operationLog.filter((entry) => entry === "merge:issue-1").length;
await assert.rejects(() => claimOrchestrator.landAndComplete("issue-1", "https://github.com/acme/app/pull/1"), (error) => error.code === "claim-conflict");
assert.equal(operationLog.filter((entry) => entry === "merge:issue-1").length, mergesBeforeCompletedStatus, "completed Linear issue passed the fresh pre-merge status check");
completeDuringPrepare = false;
remoteStates.set("issue-1", "status-progress");
const landing = await claimOrchestrator.landAndComplete("issue-1", "https://github.com/acme/app/pull/1");
assert.equal(landing.green, true);
assert(operationLog.indexOf("merge:issue-1") < operationLog.indexOf("complete:issue-1"), "Linear closed before landing confirmation");
rmSync(killPath);
assert.equal(claimOrchestrator.reportStatus().active, true, "removing the kill switch did not resume valid new intake");
assert.equal(claimOrchestrator.reportStatus().diagnostics.some((line) => line.includes("KILL is present")), false);

const redJournal = new m.DurableJournal(join(temp, "red", "journal.jsonl"), fakeClock);
redJournal.appendEvent(secondEvent);
redJournal.append("decision", secondDecision.id, secondDecision, `decision:${secondDecision.id}`);
const redOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: redJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: join(temp, "red", "KILL") });
const redDispatched = await redOrchestrator.dispatchIssue(secondDecision.id, "issue-2", { harness: "pi" });
taskPrs.set(redDispatched.taskId, "https://github.com/acme/app/pull/2");
await redOrchestrator.linkPullRequest("issue-2", "https://github.com/acme/app/pull/2");
redLanding = true;
const completeBeforeRed = operationLog.filter((entry) => entry === "complete:issue-2").length;
await assert.rejects(() => redOrchestrator.landAndComplete("issue-2", "https://github.com/acme/app/pull/2"), (error) => error.code === "landing-unconfirmed");
assert.equal(operationLog.filter((entry) => entry === "complete:issue-2").length, completeBeforeRed, "red work closed Linear");

// A crash after the forge accepted the merge but before merge-confirmed was
// journaled must verify the durable expected head and close Linear without a
// second merge or a surviving task record.
const crashEvent = {
  ...issueEvent,
  id: "linear:workspace-1:issue-3:2026-08-25T01:45:00.000Z",
  occurredAt: "2026-08-25T01:45:00.000Z",
  payload: { ...issueEvent.payload, issueId: "issue-3", identifier: "ENG-3", title: "Three", description: "Change src/three.ts", url: "https://linear.app/acme/issue/ENG-3/three" },
};
const crashJournal = new m.DurableJournal(join(temp, "crash", "journal.jsonl"), fakeClock);
crashJournal.appendEvent(crashEvent);
const crashBatch = batchFor(crashEvent);
const crashDecision = m.createDecision({
  batchId: crashBatch.id,
  action: "wake",
  eventIds: [crashEvent.id],
  summary: "Dispatch ENG-3.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-3", "ENG-3", "src/three.ts")],
});
crashJournal.append("decision", crashDecision.id, crashDecision, `decision:${crashDecision.id}`);
const crashOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: crashJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: join(temp, "crash", "KILL") });
const crashDispatch = await crashOrchestrator.dispatchIssue(crashDecision.id, "issue-3", { harness: "pi" });
const crashPr = "https://github.com/acme/app/pull/3";
taskPrs.set(crashDispatch.taskId, crashPr);
await crashOrchestrator.linkPullRequest("issue-3", crashPr);
const crashHead = "a".repeat(40);
const crashMergeIntent = m.stableId("merge", { issueId: "issue-3", taskId: crashDispatch.taskId, prUrl: crashPr, expectedHead: crashHead });
crashJournal.append("merge-intent", "issue-3", {
  mergeIntent: crashMergeIntent,
  taskId: crashDispatch.taskId,
  prUrl: crashPr,
  claimId: m.stableId("claim", { workspaceId: "workspace-1", ownerId: resolution.config.ownerId, issueId: "issue-3", taskId: crashDispatch.taskId }),
  expectedHead: crashHead,
  preparationEvidence: "fixture prepared",
}, `merge-intent:${crashMergeIntent}`);
crashJournal.append("merge-refused", "issue-3", {
  mergeIntent: crashMergeIntent,
  code: "firstmate-command",
  message: "transient post-merge verification failure",
}, `merge-refused:${crashMergeIntent}`);
mergedHeads.set("issue-3", crashHead);
tasks.delete(crashDispatch.taskId);
const mergesBeforeCrashRecovery = operationLog.filter((entry) => entry === "merge:issue-3").length;
await crashOrchestrator.reconcile();
assert.equal(operationLog.filter((entry) => entry === "merge:issue-3").length, mergesBeforeCrashRecovery, "restart repeated an already accepted merge");
assert(operationLog.includes("complete:issue-3"), "restart did not complete Linear after merged-head verification");
assert(crashJournal.read().some((record) => record.kind === "claim-completed" && record.key === "issue-3"));
const tamperedRecords = crashJournal.read();
tamperedRecords.find((record) => record.kind === "claim-intent").data.policyFingerprint = "claim-policy-tampered";
const tamperedPath = join(temp, "tampered", "journal.jsonl");
mkdirSync(join(temp, "tampered"), { recursive: true });
writeFileSync(tamperedPath, `${tamperedRecords.map((record) => JSON.stringify(record)).join("\n")}\n`);
const tamperedOrchestrator = new m.AutonomyOrchestrator({
  resolution,
  journal: new m.DurableJournal(tamperedPath, fakeClock),
  linear: linearMock,
  firstmate: firstmateMock,
  killSwitchPath: join(temp, "tampered", "KILL"),
});
await assert.rejects(() => tamperedOrchestrator.reconcile(), (error) => error.code === "journal-config-mismatch");

const deferredEvent = {
  ...issueEvent,
  id: "linear:workspace-1:issue-5:2026-08-25T01:50:00.000Z",
  occurredAt: "2026-08-25T01:50:00.000Z",
  payload: { ...issueEvent.payload, issueId: "issue-5", identifier: "ENG-5", title: "Five", description: "Change src/five.ts", url: "https://linear.app/acme/issue/ENG-5/five" },
};
const deferredJournal = new m.DurableJournal(join(temp, "deferred", "journal.jsonl"), fakeClock);
deferredJournal.appendEvent(deferredEvent);
const deferredBatch = batchFor(deferredEvent);
const deferredDecision = m.createDecision({
  batchId: deferredBatch.id,
  action: "wake",
  eventIds: [deferredEvent.id],
  summary: "Dispatch ENG-5 when capacity clears.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-5", "ENG-5", "src/five.ts", { dependencies: ["external-blocker"] })],
});
deferredJournal.append("decision", deferredDecision.id, deferredDecision, `decision:${deferredDecision.id}`);
const deferredOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: deferredJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: join(temp, "deferred", "KILL") });
remoteDependencies.set("issue-5", ["external-blocker"]);
capacityBlocked = true;
const claimsBeforeDeferral = operationLog.filter((entry) => entry === "claim:issue-5").length;
await assert.rejects(() => deferredOrchestrator.dispatchIssue(deferredDecision.id, "issue-5", { harness: "pi" }), (error) => error.retryable && error.code === "dependency-unresolved");
assert.equal(operationLog.filter((entry) => entry === "claim:issue-5").length, claimsBeforeDeferral, "capacity deferral claimed Linear work");
assert.equal(deferredOrchestrator.reportStatus().journal.deferredDispatches, 1);
capacityBlocked = false;
remoteDependencies.set("issue-5", []);
await deferredOrchestrator.reconcile();
assert(operationLog.includes("claim:issue-5"), "external Linear dependency completion did not replay the durable deferred dispatch");
assert.equal(deferredOrchestrator.reportStatus().journal.deferredDispatches, 0);

const boundaryJournal = new m.DurableJournal(join(temp, "boundary", "journal.jsonl"), fakeClock);
const boundaryEvent = { ...secondEvent, id: "linear:workspace-1:issue-sec:2026-08-25T02:00:00.000Z", payload: { ...secondEvent.payload, issueId: "issue-sec", identifier: "SEC-1", url: "https://linear.app/acme/issue/SEC-1/harden-auth" } };
boundaryJournal.appendEvent(boundaryEvent);
const boundaryBatch = batchFor(boundaryEvent);
const boundaryClaim = claimFor("issue-sec", "SEC-1", "src/auth.ts", {
  boundaries: { ...claimFor("x", "X-1", "x").boundaries, securitySensitive: true },
});
const boundaryDecision = m.createDecision({
  batchId: boundaryBatch.id,
  action: "wake",
  eventIds: [boundaryEvent.id],
  summary: "Security-sensitive work needs captain review.",
  reasonCodes: ["security-sensitive"],
  workClaims: [boundaryClaim],
});
boundaryJournal.append("decision", boundaryDecision.id, boundaryDecision, `decision:${boundaryDecision.id}`);
const boundaryOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: boundaryJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: join(temp, "boundary", "KILL") });
const claimCountBeforeBoundary = operationLog.filter((entry) => entry.startsWith("claim:")).length;
await assert.rejects(() => boundaryOrchestrator.dispatchIssue(boundaryDecision.id, "issue-sec", { harness: "pi" }), (error) => error.code === "stronger-boundary");
assert.equal(operationLog.filter((entry) => entry.startsWith("claim:")).length, claimCountBeforeBoundary, "stronger boundary reached Linear claim mutation");

const unsupportedJournal = new m.DurableJournal(join(temp, "unsupported", "journal.jsonl"), fakeClock);
const unsupportedEvent = {
  ...secondEvent,
  id: "linear:workspace-1:issue-unsupported:2026-08-25T02:05:00.000Z",
  payload: { ...secondEvent.payload, issueId: "issue-unsupported", identifier: "ENG-4", title: "Clarify copy", description: "Change the account heading.", url: "https://linear.app/acme/issue/ENG-4/clarify-copy" },
};
unsupportedJournal.appendEvent(unsupportedEvent);
const unsupportedBatch = batchFor(unsupportedEvent);
const unsupportedDecision = m.createDecision({
  batchId: unsupportedBatch.id,
  action: "wake",
  eventIds: [unsupportedEvent.id],
  summary: "Dispatch ENG-4.",
  reasonCodes: ["new-issue"],
  workClaims: [claimFor("issue-unsupported", "ENG-4", "src/admin/delete-account.ts")],
});
unsupportedJournal.append("decision", unsupportedDecision.id, unsupportedDecision, `decision:${unsupportedDecision.id}`);
const unsupportedOrchestrator = new m.AutonomyOrchestrator({ resolution, journal: unsupportedJournal, linear: linearMock, firstmate: firstmateMock, killSwitchPath: join(temp, "unsupported", "KILL") });
const claimsBeforeUnsupported = operationLog.filter((entry) => entry.startsWith("claim:")).length;
await assert.rejects(() => unsupportedOrchestrator.dispatchIssue(unsupportedDecision.id, "issue-unsupported", { harness: "pi" }), (error) => error.code === "claim-evidence");
assert.equal(operationLog.filter((entry) => entry.startsWith("claim:")).length, claimsBeforeUnsupported, "unsupported predicted scope reached Linear claim mutation");

// Persisted usage exposes cache/cost observability without prompt or tool data.
claimsJournal.append("usage", "turn-1", { provider: "fixture", model: "cheap", input: 100, output: 10, cacheRead: 900, cacheWrite: 100, costUsd: 0.01 }, "usage:turn-1");
const status = claimOrchestrator.reportStatus();
assert.equal(status.journal.usage.cacheReadRatio, 0.9);
assert.equal(status.journal.usage.costUsd, 0.01);
assert.equal(JSON.stringify(status).includes(env.FM_TEST_LINEAR_KEY), false);

console.log("ok - Pi autonomy core passes durable routing, Linear, conflict, capacity, claim, replay, kill, and green-ordering fixtures");
JS

pass "Pi autonomy core executable interface and held-out baseline hold"
