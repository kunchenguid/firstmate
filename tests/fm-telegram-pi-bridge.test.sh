#!/usr/bin/env bash
# Conformance tests for durable external-turn adoption in the active Pi session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail "node is required for Pi bridge conformance"
command -v pi >/dev/null 2>&1 || fail "pi is required for Pi bridge conformance"

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed Pi package not found"
[ "$(pi --version)" = "0.80.10" ] || fail "Pi bridge conformance is pinned to Pi 0.80.10"

TMP_ROOT=$(fm_test_tmproot fm-telegram-pi-bridge)
mkdir -p "$TMP_ROOT/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-primary-telegram-bridge.ts" "$TMP_ROOT/fm-primary-telegram-bridge.ts"
cp "$ROOT/.pi/extensions/fm-primary-telegram-bridge-core.ts" "$TMP_ROOT/fm-primary-telegram-bridge-core.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
printf '{"type":"module"}\n' > "$TMP_ROOT/package.json"

(
  cd "$TMP_ROOT" || exit 1
  node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";
import {
  ActiveSessionBridge,
  BRIDGE_CUSTOM_TYPE,
} from "./fm-primary-telegram-bridge-core.ts";

const hash = (digit) => digit.repeat(64);
const outputs = [];
const scheduled = [];
const entries = [];
let sent;
let idle = true;

const access = {
  getEntries: () => entries,
  isIdle: () => idle,
  sendMessage: (message, options) => {
    sent = { message, options };
  },
};
const bridge = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => outputs.push(output),
  schedule: (callback) => scheduled.push(callback),
});
bridge.start("session-a", access);
bridge.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "bind-a",
  routeId: "route-a",
  sessionEpoch: 7,
  expectedSessionId: "session-a",
});

const offer = {
  type: "turn.offer",
  protocolVersion: 1,
  requestId: "offer-crash",
  externalId: "external-crash",
  payloadSha256: hash("a"),
  routeId: "route-a",
  sessionEpoch: 7,
  kind: "message",
  sourceLabel: "external",
  text: "crash boundary",
};

bridge.handle(offer);
assert.equal(sent.options.deliverAs, "followUp", "ordinary delivery must default to followUp");
assert.equal(outputs.some((output) => output.status === "ACCEPTED"), false, "send return must not acknowledge");

bridge.onMessageEnd({
  role: "custom",
  customType: BRIDGE_CUSTOM_TYPE,
  content: sent.message.content,
  details: sent.message.details,
});
assert.equal(scheduled.length, 1, "message_end must schedule a post-event verifier");
assert.equal(outputs.some((output) => output.status === "ACCEPTED"), false, "pre-persistence event must not acknowledge");

entries.push({
  type: "custom_message",
  id: "entry-crash",
  customType: BRIDGE_CUSTOM_TYPE,
  details: sent.message.details,
});
bridge.shutdown("SESSION_RELOAD");
scheduled.shift()();
assert.equal(outputs.some((output) => output.status === "ACCEPTED"), false, "stale verifier must not acknowledge");
assert.equal(
  outputs.some((output) => output.status === "UNAVAILABLE" && output.reasonCode === "SESSION_SHUTDOWN_BEFORE_PERSISTENCE"),
  true,
  "shutdown must close an in-flight adoption deterministically",
);

const restartedOutputs = [];
const restarted = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => restartedOutputs.push(output),
});
restarted.start("session-a", {
  ...access,
  sendMessage: () => {
    throw new Error("reconcile must not inject");
  },
});
restarted.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "bind-restart",
  routeId: "route-a",
  sessionEpoch: 8,
});
restarted.handle({
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "reconcile-after-persist",
  externalId: offer.externalId,
  payloadSha256: offer.payloadSha256,
  routeId: "route-a",
  sessionEpoch: 8,
});
assert.equal(
  restartedOutputs.some((output) => output.status === "DUPLICATE" && output.piEntryId === "entry-crash"),
  true,
  "restart after persistence must recover the original marker",
);

const emptyOutputs = [];
const empty = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => emptyOutputs.push(output),
});
empty.start("session-b", {
  getEntries: () => [],
  isIdle: () => true,
  sendMessage: () => {},
});
empty.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "bind-empty",
  routeId: "route-a",
  sessionEpoch: 9,
});
empty.handle({
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "crash-before-or-unpersisted",
  externalId: "external-not-persisted",
  payloadSha256: hash("b"),
  routeId: "route-a",
  sessionEpoch: 9,
});
assert.equal(
  emptyOutputs.some((output) => output.status === "NOT_FOUND"),
  true,
  "crash before injection or persistence must reconcile as not found",
);

empty.handle({
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "stale-reconcile",
  externalId: "external-not-persisted",
  payloadSha256: hash("b"),
  routeId: "route-a",
  sessionEpoch: 8,
});
assert.equal(
  emptyOutputs.some((output) => output.requestId === "stale-reconcile" && output.status === "STALE_EPOCH"),
  true,
  "old epochs must be rejected",
);
empty.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "competing-bind",
  routeId: "route-other",
  sessionEpoch: 10,
});
assert.equal(
  emptyOutputs.some(
    (output) => output.requestId === "competing-bind"
      && output.status === "UNAVAILABLE"
      && output.reasonCode === "COMPETING_ROUTE_BINDING",
  ),
  true,
  "a live session must refuse competing route claims",
);

const unsupportedOutputs = [];
const unsupported = new ActiveSessionBridge({
  piVersion: "0.80.11",
  emit: (output) => unsupportedOutputs.push(output),
});
unsupported.start("session-c", access);
assert.equal(
  unsupportedOutputs.some((output) => output.state === "UNAVAILABLE" && output.reasonCode === "UNSUPPORTED_PI_VERSION"),
  true,
  "unproven Pi versions must fail closed",
);

const ephemeralOutputs = [];
const ephemeral = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => ephemeralOutputs.push(output),
});
ephemeral.start("session-ephemeral", {
  getEntries: () => [],
  isPersisted: () => false,
  isIdle: () => true,
  sendMessage: () => {},
});
assert.equal(
  ephemeralOutputs.some((output) => output.state === "UNAVAILABLE" && output.reasonCode === "SESSION_NOT_PERSISTED"),
  true,
  "ephemeral sessions must not advertise durable adoption",
);

const unpersistedOutputs = [];
let injectionAttempted = false;
const unpersisted = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => unpersistedOutputs.push(output),
});
unpersisted.start("session-before-crash", {
  getEntries: () => [],
  isIdle: () => true,
  sendMessage: () => {
    injectionAttempted = true;
  },
});
unpersisted.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "bind-before-crash",
  routeId: "route-a",
  sessionEpoch: 10,
});
unpersisted.handle({
  ...offer,
  requestId: "injected-not-persisted",
  externalId: "external-injected-not-persisted",
  sessionEpoch: 10,
});
assert.equal(injectionAttempted, true, "crash fixture must reach the injection call");
unpersisted.shutdown("PROCESS_CRASH");

const afterUnpersistedCrashOutputs = [];
const afterUnpersistedCrash = new ActiveSessionBridge({
  piVersion: "0.80.10",
  emit: (output) => afterUnpersistedCrashOutputs.push(output),
});
afterUnpersistedCrash.start("session-after-crash", {
  getEntries: () => [],
  isIdle: () => true,
  sendMessage: () => {},
});
afterUnpersistedCrash.handle({
  type: "session.bind",
  protocolVersion: 1,
  requestId: "bind-after-crash",
  routeId: "route-a",
  sessionEpoch: 11,
});
afterUnpersistedCrash.handle({
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "reconcile-injected-not-persisted",
  externalId: "external-injected-not-persisted",
  payloadSha256: offer.payloadSha256,
  routeId: "route-a",
  sessionEpoch: 11,
});
assert.equal(
  afterUnpersistedCrashOutputs.some(
    (output) => output.requestId === "reconcile-injected-not-persisted" && output.status === "NOT_FOUND",
  ),
  true,
  "crash after injection but before persistence must reconcile as not found",
);
NODE
) || fail "Pi bridge lifecycle and crash-boundary conformance failed"
pass "Pi bridge lifecycle and crash-boundary conformance"

(
  cd "$TMP_ROOT" || exit 1
  node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  BRIDGE_CUSTOM_TYPE,
  BRIDGE_INPUT_CHANNEL,
  BRIDGE_OUTPUT_CHANNEL,
} from "./fm-primary-telegram-bridge-core.ts";
import {
  createAgentSession,
  createEventBus,
  convertToLlm,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  VERSION,
} from "@earendil-works/pi-coding-agent";
import {
  createFauxCore,
  fauxAssistantMessage,
} from "@earendil-works/pi-ai";

assert.equal(VERSION, "0.80.10", "installed Pi API version drifted");

const plugin = resolve("fm-primary-telegram-bridge.ts");
const lab = mkdtempSync(join(tmpdir(), "fm-pi-bridge-real."));
const cwd = join(lab, "project");
const agentDir = join(lab, "agent");
const sessionDir = join(lab, "sessions");
mkdirSync(cwd, { recursive: true });
mkdirSync(agentDir, { recursive: true });
mkdirSync(sessionDir, { recursive: true });

const faux = createFauxCore({
  api: "fm-faux-api",
  provider: "fm-faux",
  models: [{
    id: "fm-faux-model",
    name: "Firstmate faux model",
    reasoning: false,
    input: ["text"],
    contextWindow: 128000,
    maxTokens: 4096,
  }],
});
const modelRuntime = await ModelRuntime.create({
  authPath: join(lab, "auth.json"),
  modelsPath: null,
  allowModelNetwork: false,
});
modelRuntime.registerProvider("fm-faux", {
  api: faux.api,
  baseUrl: "http://127.0.0.1.invalid",
  apiKey: "test-only",
  models: [{
    id: "fm-faux-model",
    name: "Firstmate faux model",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 4096,
  }],
  streamSimple: faux.streamSimple,
});
const model = modelRuntime.getModel("fm-faux", "fm-faux-model");
assert.ok(model, "faux model was not registered");

const hash = (digit) => digit.repeat(64);
const waitFor = async (predicate, label, attempts = 400) => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
};

async function createHarness(sessionManager, epoch) {
  const bus = createEventBus();
  const outputs = [];
  bus.on(BRIDGE_OUTPUT_CHANNEL, (output) => outputs.push(output));
  const settingsManager = SettingsManager.inMemory({
    compaction: { enabled: false },
  });
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    eventBus: bus,
    additionalExtensionPaths: [plugin],
  });
  await loader.reload();
  const created = await createAgentSession({
    cwd,
    agentDir,
    model,
    modelRuntime,
    settingsManager,
    sessionManager,
    resourceLoader: loader,
    noTools: "all",
  });
  assert.deepEqual(created.extensionsResult.errors, [], "bridge extension failed to load");
  await created.session.bindExtensions({ mode: "print" });
  bus.emit(BRIDGE_INPUT_CHANNEL, {
    type: "session.bind",
    protocolVersion: 1,
    requestId: `bind-${epoch}`,
    routeId: "route-main",
    sessionEpoch: epoch,
    expectedSessionId: sessionManager.getSessionId(),
  });
  await waitFor(
    () => outputs.find((output) => output.type === "session.state" && output.state === "READY"),
    "session ready",
  );
  return { ...created, bus, outputs, sessionManager };
}

function offer(requestId, externalId, payloadSha256, text, overrides = {}) {
  return {
    type: "turn.offer",
    protocolVersion: 1,
    requestId,
    externalId,
    payloadSha256,
    routeId: "route-main",
    sessionEpoch: 1,
    kind: "message",
    sourceLabel: "external",
    text,
    ...overrides,
  };
}

const sessionManager = SessionManager.create(cwd, sessionDir);
const harness = await createHarness(sessionManager, 1);
const { session, bus, outputs } = harness;

let preAppendCount = -1;
session.subscribe((event) => {
  if (event.type !== "message_end" || event.message.role !== "custom") return;
  const details = event.message.details;
  if (details?.request_id !== "idle") return;
  preAppendCount = sessionManager.getEntries().filter(
    (entry) => entry.type === "custom_message" && entry.details?.request_id === "idle",
  ).length;
});

faux.setResponses([fauxAssistantMessage("idle complete")]);
bus.emit(BRIDGE_INPUT_CHANNEL, offer("idle", "external-idle", hash("1"), "idle injection"));
const idleAccepted = await waitFor(
  () => outputs.find((output) => output.requestId === "idle" && output.status === "ACCEPTED"),
  "idle acceptance",
);
await session.agent.waitForIdle();
assert.equal(preAppendCount, 0, "message_end must precede the session append");
assert.equal(idleAccepted.deliverAs, "followUp", "idle ordinary message must use followUp");
assert.equal(
  sessionManager.getEntries().filter(
    (entry) => entry.type === "custom_message" && entry.details?.external_id === "external-idle",
  ).length,
  1,
  "idle injection must persist exactly one marker",
);

const llmMessages = convertToLlm(sessionManager.buildSessionContext().messages);
assert.equal(
  JSON.stringify(llmMessages).includes("external-idle"),
  false,
  "external identifiers must be absent from LLM-visible messages",
);
assert.equal(
  JSON.stringify(sessionManager.getEntries()).includes("external-idle"),
  true,
  "external identifiers must persist in session details",
);

bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "idle-duplicate",
  externalId: "external-idle",
  payloadSha256: hash("1"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find((output) => output.requestId === "idle-duplicate" && output.status === "DUPLICATE"),
  "exact duplicate",
);

bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "idle-mismatch",
  externalId: "external-idle",
  payloadSha256: hash("2"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find(
    (output) => output.requestId === "idle-mismatch"
      && output.status === "AMBIGUOUS"
      && output.reasonCode === "MISMATCHED_HASH",
  ),
  "hash mismatch quarantine",
);

bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "not-found",
  externalId: "external-missing",
  payloadSha256: hash("3"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find((output) => output.requestId === "not-found" && output.status === "NOT_FOUND"),
  "not found result",
);

bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "stale-epoch",
  externalId: "external-missing",
  payloadSha256: hash("3"),
  routeId: "route-main",
  sessionEpoch: 0,
});
await waitFor(
  () => outputs.find((output) => output.requestId === "stale-epoch" && output.status === "UNAVAILABLE"),
  "invalid epoch result",
);
bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "old-epoch",
  externalId: "external-missing",
  payloadSha256: hash("3"),
  routeId: "route-main",
  sessionEpoch: 2,
});
await waitFor(
  () => outputs.find((output) => output.requestId === "old-epoch" && output.status === "STALE_EPOCH"),
  "stale epoch result",
);

let releaseBusy;
const busyGate = new Promise((resolveGate) => {
  releaseBusy = resolveGate;
});
faux.setResponses([
  async () => {
    await busyGate;
    return fauxAssistantMessage("local turn complete");
  },
  fauxAssistantMessage("busy follow-up complete"),
]);
const localBusy = session.prompt("hold a local turn open");
await waitFor(() => session.isStreaming, "busy local turn");
bus.emit(BRIDGE_INPUT_CHANNEL, offer("busy-followup", "external-busy", hash("4"), "queued ordinary message"));
bus.emit(BRIDGE_INPUT_CHANNEL, offer("busy-second", "external-busy-second", hash("5"), "second in-flight message"));
await waitFor(
  () => outputs.find(
    (output) => output.requestId === "busy-second"
      && output.status === "BUSY"
      && output.reasonCode === "ADOPTION_IN_FLIGHT",
  ),
  "single in-flight adoption",
);
releaseBusy();
await localBusy;
const busyAccepted = await waitFor(
  () => outputs.find((output) => output.requestId === "busy-followup" && output.status === "ACCEPTED"),
  "busy follow-up acceptance",
);
assert.equal(busyAccepted.deliverAs, "followUp", "ordinary busy message must use followUp");

let releaseCorrection;
const correctionGate = new Promise((resolveGate) => {
  releaseCorrection = resolveGate;
});
faux.setResponses([
  async () => {
    await correctionGate;
    return fauxAssistantMessage("base external turn complete");
  },
  fauxAssistantMessage("correction applied"),
]);
bus.emit(BRIDGE_INPUT_CHANNEL, offer("base-external", "external-base", hash("6"), "base external turn"));
await waitFor(
  () => outputs.find((output) => output.requestId === "base-external" && output.status === "ACCEPTED"),
  "base external acceptance",
);
assert.equal(session.isStreaming, true, "base external turn must still be active for correction");
bus.emit(BRIDGE_INPUT_CHANNEL, offer(
  "unbound-correction",
  "external-unbound-correction",
  hash("7"),
  "must not steer",
  {
    kind: "correction",
    authenticatedCorrection: false,
    supersedesExternalId: "external-base",
  },
));
await waitFor(
  () => outputs.find(
    (output) => output.requestId === "unbound-correction"
      && output.status === "BUSY"
      && output.reasonCode === "CORRECTION_NOT_BOUND",
  ),
  "unbound correction refusal",
);
bus.emit(BRIDGE_INPUT_CHANNEL, offer(
  "correction",
  "external-correction",
  hash("7"),
  "correct the active request",
  {
    kind: "correction",
    authenticatedCorrection: true,
    supersedesExternalId: "external-base",
  },
));
releaseCorrection();
const correctionAccepted = await waitFor(
  () => outputs.find((output) => output.requestId === "correction" && output.status === "ACCEPTED"),
  "correction acceptance",
);
await session.agent.waitForIdle();
assert.equal(correctionAccepted.deliverAs, "steer", "bound authenticated correction must steer");

let releaseRapid;
const rapidGate = new Promise((resolveGate) => {
  releaseRapid = resolveGate;
});
faux.setResponses([
  async () => {
    await rapidGate;
    return fauxAssistantMessage("rapid first complete");
  },
  fauxAssistantMessage("rapid second complete"),
]);
bus.emit(BRIDGE_INPUT_CHANNEL, offer("rapid-1", "external-rapid-1", hash("8"), "identical rapid text"));
await waitFor(
  () => outputs.find((output) => output.requestId === "rapid-1" && output.status === "ACCEPTED"),
  "first rapid acceptance",
);
bus.emit(BRIDGE_INPUT_CHANNEL, offer("rapid-2", "external-rapid-2", hash("9"), "identical rapid text"));
releaseRapid();
await waitFor(
  () => outputs.find((output) => output.requestId === "rapid-2" && output.status === "ACCEPTED"),
  "second rapid acceptance",
);
await session.agent.waitForIdle();
assert.equal(
  sessionManager.getEntries().filter(
    (entry) => entry.type === "custom_message"
      && ["external-rapid-1", "external-rapid-2"].includes(entry.details?.external_id),
  ).length,
  2,
  "identical text with distinct external IDs must persist as two markers",
);

faux.setResponses([fauxAssistantMessage("compaction marker complete")]);
bus.emit(BRIDGE_INPUT_CHANNEL, offer("compact-marker", "external-compact", hash("a"), "survive compaction"));
await waitFor(
  () => outputs.find((output) => output.requestId === "compact-marker" && output.status === "ACCEPTED"),
  "compaction marker acceptance",
);
await session.agent.waitForIdle();
const keptId = sessionManager.appendMessage({
  role: "user",
  content: [{ type: "text", text: "kept after compaction" }],
  timestamp: Date.now(),
});
sessionManager.appendCompaction("forced conformance summary", keptId, 1000);
assert.equal(
  sessionManager.buildContextEntries().some(
    (entry) => entry.type === "custom_message" && entry.details?.external_id === "external-compact",
  ),
  false,
  "forced compaction must remove the old marker from active semantic context",
);
bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "compact-reconcile",
  externalId: "external-compact",
  payloadSha256: hash("a"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find((output) => output.requestId === "compact-reconcile" && output.status === "DUPLICATE"),
  "full-entry compaction reconciliation",
);

const marker = sessionManager.getEntries().find(
  (entry) => entry.type === "custom_message" && entry.details?.external_id === "external-compact",
);
sessionManager.appendCustomMessageEntry(
  BRIDGE_CUSTOM_TYPE,
  "duplicate corruption fixture",
  false,
  marker.details,
);
bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "multiple-markers",
  externalId: "external-compact",
  payloadSha256: hash("a"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find(
    (output) => output.requestId === "multiple-markers"
      && output.status === "AMBIGUOUS"
      && output.reasonCode === "MULTIPLE_MARKERS",
  ),
  "multiple marker quarantine",
);

sessionManager.appendCustomMessageEntry(
  BRIDGE_CUSTOM_TYPE,
  "malformed corruption fixture",
  false,
  {
    schema_version: 1,
    external_id: "external-malformed",
    payload_sha256: hash("b"),
    route_id: "route-main",
    session_epoch: 1,
  },
);
bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "invalid-marker",
  externalId: "external-malformed",
  payloadSha256: hash("b"),
  routeId: "route-main",
  sessionEpoch: 1,
});
await waitFor(
  () => outputs.find(
    (output) => output.requestId === "invalid-marker"
      && output.status === "AMBIGUOUS"
      && output.reasonCode === "INVALID_MARKER",
  ),
  "invalid marker quarantine",
);

await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
session.dispose();

const sessionFile = sessionManager.getSessionFile();
const reopenedManager = SessionManager.open(sessionFile, sessionDir);
const restarted = await createHarness(reopenedManager, 2);
restarted.bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "restart-reconcile",
  externalId: "external-idle",
  payloadSha256: hash("1"),
  routeId: "route-main",
  sessionEpoch: 2,
});
await waitFor(
  () => restarted.outputs.find(
    (output) => output.requestId === "restart-reconcile" && output.status === "DUPLICATE",
  ),
  "restart reconciliation",
);
await restarted.session.extensionRunner.emit({ type: "session_shutdown", reason: "fork" });
restarted.session.dispose();

const replacementManager = SessionManager.create(cwd, join(lab, "replacement-sessions"));
const replacement = await createHarness(replacementManager, 3);
replacement.bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "replacement-old-marker",
  externalId: "external-idle",
  payloadSha256: hash("1"),
  routeId: "route-main",
  sessionEpoch: 3,
});
await waitFor(
  () => replacement.outputs.find(
    (output) => output.requestId === "replacement-old-marker" && output.status === "NOT_FOUND",
  ),
  "replacement session isolation",
);
replacement.bus.emit(BRIDGE_INPUT_CHANNEL, {
  type: "turn.reconcile",
  protocolVersion: 1,
  requestId: "replacement-stale-ack",
  externalId: "external-idle",
  payloadSha256: hash("1"),
  routeId: "route-main",
  sessionEpoch: 2,
});
await waitFor(
  () => replacement.outputs.find(
    (output) => output.requestId === "replacement-stale-ack" && output.status === "STALE_EPOCH",
  ),
  "replacement stale epoch refusal",
);
await replacement.session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
replacement.session.dispose();
rmSync(lab, { recursive: true, force: true });
NODE
) || fail "installed Pi active-session adoption conformance failed"
pass "installed Pi 0.80.10 active-session adoption conformance"
