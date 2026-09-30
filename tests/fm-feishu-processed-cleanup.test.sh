#!/usr/bin/env bash
# Behavioral regression for lifecycle-owned processed Feishu body cleanup.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-feishu-processed-cleanup)
trap fm_test_cleanup EXIT
HOME_DIR="$TMP_ROOT/home"
SESSION_DIR="$TMP_ROOT/session"
SESSION_FILE="$SESSION_DIR/current.jsonl"
LOCK_SCRIPT="$TMP_ROOT/lock-status.sh"
LIFECYCLE_SCRIPT="$TMP_ROOT/lifecycle-noop.mjs"
SID=12345678-1234-1234-1234-123456789abc
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$SESSION_DIR"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$SESSION_DIR" > "$SESSION_FILE"
cat > "$HOME_DIR/config/feishu.env" <<'EOF'
FM_FEISHU_ENABLED=true
FM_FEISHU_APP_ID=cli_0123456789abcdef
FM_FEISHU_APP_SECRET=fixture-secret-never-logged
FM_FEISHU_CAPTAIN_OPEN_ID=ou_captain1234
FM_FEISHU_P2P_CHAT_ID=oc_chat1234
EOF
chmod 600 "$HOME_DIR/config/feishu.env"
cat > "$LOCK_SCRIPT" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/delay-lock" ]; then
  touch "$FM_HOME/lock-running"
  sleep 0.1
fi
printf 'owned\n'
SH
chmod +x "$LOCK_SCRIPT"
printf '%s\n' 'process.stdin.resume();' > "$LIFECYCLE_SCRIPT"

FM_HOME="$HOME_DIR" \
FM_ROOT_OVERRIDE="$ROOT" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_LIFECYCLE_SCRIPT="$LIFECYCLE_SCRIPT" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
FM_FEISHU_PROCESS_RECOVERY_TEST_MODE=1 \
FM_FEISHU_PUMP_MS=10 \
SESSION_FILE="$SESSION_FILE" \
SESSION_DIR="$SESSION_DIR" \
SID="$SID" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  bindSession,
  claimNextOutbound,
  claimTransportOwner,
  cleanupProcessedFeishuBodies,
  convergeConfiguredSession,
  createPairing,
  failOutboundAttempt,
  findInboundByDeliveryRef,
  ingressCounts,
  offerFeishuIngress,
  pathsForHome,
  repairInboundLedgers,
  repairOutboundState,
  reconcileFeishuIngress,
  pendingFeishuIngress,
  persistAssistantOutboundIntent,
  publishFeishuInbound,
  receiptOutbound,
  verifyFeishuSessionMessage,
  registerAssistantOutbound,
  writeTransportHealth,
  IDEMPOTENCY_WINDOW_MS,
} from "./bin/fm-feishu-state.mjs";
import {
  parseFeishuMessage,
  registerFeishuNativeChannel,
} from "./.pi/extensions/lib/fm-feishu-native-channel.ts";

let clock = Date.now();
Date.now = () => clock;
const home = process.env.FM_HOME;
const sessionId = process.env.SID;
const sessionFile = process.env.SESSION_FILE;
const sessionCwd = process.env.SESSION_DIR;
const paths = pathsForHome(home);
const pairing = createPairing(home, {
  appIdFingerprint: `sha256:${"1".repeat(64)}`,
  allowedUser: "ou_captain1234",
  allowedChat: "oc_chat1234",
});
const binding = bindSession(home, {
  sessionId,
  sessionFile,
  sessionCwd,
  headerId: sessionId,
  headerCwd: sessionCwd,
  outboundAfterEntryId: null,
});
const procStat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
const processStartToken = procStat.slice(procStat.lastIndexOf(")") + 2).trim().split(/\s+/)[19];
const ownerNonce = "a".repeat(48);
assert.equal(claimTransportOwner(home, {
  nonce: ownerNonce,
  moduleFile: join(process.cwd(), "bin/fm-feishu-transport.mjs"),
  processStartToken,
  configFileIdentity: "1:2:3:4",
}).ok, true);
const setTransport = (healthy) => writeTransportHealth(home, {
  phase: healthy ? "healthy" : "degraded",
  healthy,
  ownerPid: process.pid,
  ownerNonce,
  ownerProcessStartToken: processStartToken,
  bindingId: binding.binding_id,
  bindingGeneration: binding.generation,
  lastErrorType: healthy ? null : "fixture-paused",
  recoveryClass: healthy ? null : "retryable",
});
setTransport(true);

const entries = [];
function context() {
  return {
    mode: "tui",
    hasUI: true,
    cwd: sessionCwd,
    isProjectTrusted: () => true,
    isIdle: () => true,
    sessionManager: {
      getSessionFile: () => sessionFile,
      getSessionId: () => sessionId,
      getHeader: () => ({ id: sessionId, cwd: sessionCwd }),
      getEntries: () => entries,
    },
    ui: { notify() {}, setStatus() {} },
  };
}
function fakePi() {
  const handlers = new Map();
  const sends = [];
  const events = new Map();
  return {
    handlers,
    sends,
    events: {
      on(name, handler) {
        const listeners = events.get(name) ?? new Set();
        listeners.add(handler);
        events.set(name, listeners);
        return () => listeners.delete(handler);
      },
    },
    on(name, handler) {
      const list = handlers.get(name) ?? [];
      list.push(handler);
      handlers.set(name, list);
    },
    sendMessage(message, options) { sends.push({ message: { role: "custom", ...message }, options }); },
    appendEntry() {},
  };
}
async function emit(pi, name, event, ctx) {
  const results = [];
  for (const handler of pi.handlers.get(name) ?? []) results.push(await handler({ type: name, ...event }, ctx));
  return results;
}
async function waitFor(predicate, label) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}
const inbound = (suffix, content) => ({
  event_id: `evt_${suffix}`,
  message_id: `om_${suffix}1234`,
  sender_id: "ou_captain1234",
  sender_type: "user",
  chat_id: "oc_chat1234",
  chat_type: "p2p",
  message_type: "text",
  content,
  create_time: "1",
});
const delivered = publishFeishuInbound(home, inbound("delivered", "processed inbound body"));
const pi = fakePi();
registerFeishuNativeChannel(pi);
const ctx = context();
await emit(pi, "session_start", { reason: "startup" }, ctx);
await waitFor(() => pi.sends.length === 1, "initial inbound offer");
const deliveredMessage = pi.sends[0].message;
entries.push({
  type: "custom_message",
  id: "10000001",
  parentId: null,
  timestamp: new Date(clock).toISOString(),
  customType: deliveredMessage.customType,
  content: deliveredMessage.content,
  display: deliveredMessage.display,
  details: deliveredMessage.details,
});
await emit(pi, "message_start", { message: deliveredMessage }, ctx);
assert.equal(ingressCounts(home).delivered, 1, "fixture inbound did not reach the processed boundary");
setTransport(false);
const pending = publishFeishuInbound(home, inbound("pending", "pending inbound body"));
const offered = publishFeishuInbound(home, inbound("offered", "offered inbound body"));
assert(offerFeishuIngress(home, offered.deliveryRef, {
  sessionId,
  bindingId: binding.binding_id,
  bindingGeneration: binding.generation,
}), "offered fixture did not enter the in-flight state");

let outboundOrder = 10;
function createOutbound(text, maxChunkBytes = 1024) {
  const id = outboundOrder.toString(16).padStart(8, "0");
  const result = registerAssistantOutbound(home, {
    text,
    assistantEntryId: id,
    sessionOrder: outboundOrder++,
    sessionEntryTimestamp: new Date(clock).toISOString(),
    sessionId,
    bindingGeneration: binding.generation,
    maxChunkBytes,
  });
  assert.equal(result.status, "registered");
  return result;
}
const posted = createOutbound("successfully posted outbound body");
let claim = claimNextOutbound(home, { nowMs: clock });
assert(claim, "posted fixture was not claimable");
assert.equal(receiptOutbound(home, claim, { messageId: "om_postedReceipt1", chatId: "oc_chat1234" }), true);

createOutbound("unknown outbound body");
claim = claimNextOutbound(home, { nowMs: clock });
assert(claim, "unknown fixture was not claimable");
assert.equal(failOutboundAttempt(home, claim, "unknown result", { ambiguous: true, nowMs: clock + IDEMPOTENCY_WINDOW_MS }), true);

createOutbound("partial send body with several words", 16);
claim = claimNextOutbound(home, { nowMs: clock });
assert(claim && claim.outbox.chunks.length > 1, "partial-send fixture did not produce multiple chunks");
assert.equal(receiptOutbound(home, claim, { messageId: "om_partialReceipt1", chatId: "oc_chat1234" }), true);

createOutbound("plain pending outbound body");

const messageFileCount = () => readdirSync(paths.inbox).length + readdirSync(paths.outbox).length;
const deliveredInboundName = readdirSync(paths.inbox).find((name) => JSON.parse(readFileSync(join(paths.inbox, name), "utf8")).delivery_ref === delivered.deliveryRef);
const deliveredInboundPath = join(paths.inbox, deliveredInboundName);
const deliveredInboundRecord = JSON.parse(readFileSync(deliveredInboundPath, "utf8"));
const postedTextHash = `sha256:${createHash("sha256").update("successfully posted outbound body").digest("hex")}`;
const postedOutboundName = readdirSync(paths.outbox).find((name) => JSON.parse(readFileSync(join(paths.outbox, name), "utf8")).text_hash === postedTextHash);
const postedOutboundPath = join(paths.outbox, postedOutboundName);
const postedOutboundRecord = JSON.parse(readFileSync(postedOutboundPath, "utf8"));
const deliveredLedger = JSON.parse(readFileSync(join(paths.inboundLedger, deliveredInboundName), "utf8"));
const deliveredMapName = createHash("sha256").update(delivered.deliveryRef).digest("hex") + ".json";
const deliveredMap = JSON.parse(readFileSync(join(paths.inboundDeliveryMap, deliveredMapName), "utf8"));
const originalPostedLedger = JSON.parse(readFileSync(join(paths.outboundLedger, postedOutboundName), "utf8"));
const originalPostedReceipt = JSON.parse(readFileSync(join(paths.outboundReceipts, postedOutboundName), "utf8"));
const counts = () => Object.fromEntries(["inbox", "inboundLedger", "inboundDeliveryMap", "outbox", "outboundLedger", "outboundReceipts"].map(key => [key, readdirSync(paths[key]).length]));
const before = counts();
assert.equal(messageFileCount(), 7, "before-count fixture did not contain every inbound and outbound message file");
clock += 4999;
await new Promise((resolve) => setTimeout(resolve, 30));
assert.equal(messageFileCount(), 7, "processed message cleanup ran before the five-second boundary");
clock += 1;
await waitFor(() => messageFileCount() === 5, "five-second processed-message cleanup");
assert.equal(messageFileCount(), 5, "after-count did not remove exactly the two safely processed message files");
assert(!existsSync(deliveredInboundPath), "delivered inbound JSON file survived cleanup");
assert(!existsSync(postedOutboundPath), "posted outbound JSON file survived cleanup");
for (const path of [join(paths.inboundLedger, deliveredInboundName), join(paths.inboundDeliveryMap, deliveredMapName), join(paths.outboundLedger, postedOutboundName)]) assert(!existsSync(path), `processed ledger/map survived: ${path}`);
assert.deepEqual(counts(), { inbox: 2, inboundLedger: 2, inboundDeliveryMap: 2, outbox: 3, outboundLedger: 3, outboundReceipts: 2 });
assert.equal(verifyFeishuSessionMessage(home, entries[0]), true, "processed inbound lost immutable session-routing proof");
assert.equal(verifyFeishuSessionMessage(home, { ...entries[0], content: [{ type: "text", text: "altered body" }] }), false, "processed inbound accepted altered session content");
console.log("evidence - record classes", JSON.stringify({ before, after: counts() }));

assert.equal(findInboundByDeliveryRef(home, delivered.deliveryRef), undefined, "deleted inbound message remained readable as a tombstone");
assert.equal(findInboundByDeliveryRef(home, pending.deliveryRef).content[0].text, "pending inbound body", "pending inbound body was removed");
assert.equal(findInboundByDeliveryRef(home, offered.deliveryRef).content[0].text, "offered inbound body", "offered inbound body was removed");
const contextResult = await emit(pi, "context", { messages: [deliveredMessage] }, ctx);
assert.deepEqual(contextResult[0].messages, [], "compacted inbound history was rehydrated into provider context");
const legacyContextResult = await emit(pi, "context", { messages: [{
  role: "user",
  content: `\u2063FIRSTMATE_FEISHU: v1 ref=${delivered.deliveryRef} g=${binding.generation}\n[Source: authorized Feishu P2P message]\n---\nprocessed inbound body`,
}] }, ctx);
assert.deepEqual(legacyContextResult[0].messages, [], "compacted legacy inbound history was rehydrated into provider context");

const outboxes = readdirSync(paths.outbox).map((name) => JSON.parse(readFileSync(join(paths.outbox, name), "utf8")));
assert(!outboxes.some((record) => record.text_hash === postedTextHash), "posted outbound message remained readable as a tombstone");
for (const text of ["unknown outbound body", "partial send body with several words", "plain pending outbound body"]) {
  assert(outboxes.some((record) => record.text === text), `unprocessed outbound body was removed: ${text}`);
}

const { text: _legacyInboundText, content: _legacyInboundContent, ...legacyInboundIdentity } = deliveredInboundRecord;
writeFileSync(deliveredInboundPath, `${JSON.stringify({
  ...legacyInboundIdentity,
  schema: "fm-feishu-inbound-processed.v1",
  body_removed_at: new Date(clock).toISOString(),
}, null, 2)}\n`, { mode: 0o600 });
const { text: _legacyOutboundText, chunks: legacyOutboundChunks, rendered_text_hash: _legacyRenderedHash, ...legacyOutboundIdentity } = postedOutboundRecord;
writeFileSync(postedOutboundPath, `${JSON.stringify({
  ...legacyOutboundIdentity,
  schema: "fm-feishu-assistant-outbound-processed.v1",
  chunk_count: legacyOutboundChunks.length,
  body_removed_at: new Date(clock).toISOString(),
}, null, 2)}\n`, { mode: 0o600 });
const postedLedgerPath = join(paths.outboundLedger, postedOutboundName);
const legacyPostedLedger = originalPostedLedger;
writeFileSync(join(paths.inboundLedger, deliveredInboundName), JSON.stringify(deliveredLedger), { mode: 0o600 });
writeFileSync(join(paths.inboundDeliveryMap, deliveredMapName), JSON.stringify(deliveredMap), { mode: 0o600 });
writeFileSync(join(paths.outboundReceipts, postedOutboundName), JSON.stringify(originalPostedReceipt), { mode: 0o600 });
writeFileSync(postedLedgerPath, `${JSON.stringify(legacyPostedLedger, null, 2)}\n`, { mode: 0o600 });
assert.equal(messageFileCount(), 7, "legacy processed empty-body fixtures were not restored as message files");
clock += 4999;
await new Promise((resolve) => setTimeout(resolve, 30));
assert.equal(messageFileCount(), 7, "legacy processed message cleanup ran before its five-second boundary");
clock += 1;
await waitFor(() => messageFileCount() === 5, "five-second legacy processed-message cleanup");
assert(!existsSync(deliveredInboundPath), "legacy processed inbound JSON file survived cleanup");
assert(!existsSync(postedOutboundPath), "legacy processed outbound JSON file survived cleanup");
assert(!existsSync(postedLedgerPath), "legacy outbound ledger survived cleanup");
assert(!existsSync(join(paths.inboundLedger, deliveredInboundName)), "legacy inbound ledger survived cleanup");
assert(!existsSync(join(paths.inboundDeliveryMap, deliveredMapName)), "legacy inbound map survived cleanup");
assert.equal(JSON.parse(readFileSync(join(paths.outboundReceipts, postedOutboundName), "utf8")).text_hash, postedTextHash);

writeFileSync(join(paths.inboundLedger, deliveredInboundName), JSON.stringify(deliveredLedger), { mode: 0o600 });
writeFileSync(join(paths.inboundDeliveryMap, deliveredMapName), JSON.stringify(deliveredMap), { mode: 0o600 });
writeFileSync(postedLedgerPath, JSON.stringify({ ...originalPostedLedger, text_hash: postedTextHash }), { mode: 0o600 });
const residue = cleanupProcessedFeishuBodies(home, { nowMs: clock });
assert.equal(residue.inbound.removedLedgers, 1);
assert.equal(residue.outbound.removedLedgers, 1);
assert.equal(residue.removedFiles, 0);
const repeated = cleanupProcessedFeishuBodies(home, { nowMs: clock });
assert.equal(repeated.removedFiles, 0, "repeated cleanup was not idempotent");
assert.equal(repeated.filesBefore, 5, "cleanup before-count did not report retained unprocessed message files");
assert.equal(repeated.filesAfter, 5, "cleanup after-count changed retained unprocessed message files");
assert.equal(registerAssistantOutbound(home, {
  text: "successfully posted outbound body",
  assistantEntryId: "0000000a",
  sessionOrder: 10,
  sessionEntryTimestamp: new Date(clock - 5000).toISOString(),
  sessionId,
  bindingGeneration: binding.generation,
}).status, "duplicate", "compacted outbound identity allowed an old effect to be registered again");
assert(!existsSync(join(paths.outboundPending, postedOutboundName)), "processed outbound registration recreated a send candidate");
assert.equal(posted.eventId, JSON.parse(readFileSync(join(paths.outboundReceipts, postedOutboundName), "utf8")).event_id, "processed outbound ledger changed stable effect identity");
assert.equal(publishFeishuInbound(home, inbound("delivered", "processed inbound body")).status, "duplicate", "compacted inbound identity allowed re-delivery");
assert.equal(publishFeishuInbound(home, { ...inbound("delivered", "processed inbound body"), event_id: "evt_delivered_redelivery" }).status, "duplicate", "same-message redelivery with a new event id resurrected inbound history");

await emit(pi, "session_shutdown", { reason: "reload" }, ctx);
clock += 10000;
await new Promise((resolve) => setTimeout(resolve, 30));
assert(!existsSync(deliveredInboundPath), "disposed runtime resurrected deleted inbound history after shutdown");
const resumedPi = fakePi();
registerFeishuNativeChannel(resumedPi);
await emit(resumedPi, "session_start", { reason: "resume" }, ctx);
const resumedContext = await emit(resumedPi, "context", { messages: [deliveredMessage] }, ctx);
assert.deepEqual(resumedContext[0].messages, [], "restart readback rehydrated a compacted inbound body");
writeFileSync(join(home, "delay-lock"), "delay");
await waitFor(() => existsSync(join(home, "lock-running")), "asynchronous owner check");
const sendsBeforeShutdown = resumedPi.sends.length;
await emit(resumedPi, "session_shutdown", { reason: "fixture-complete" }, ctx);
await new Promise(resolve => setTimeout(resolve, 200));
assert.equal(resumedPi.sends.length, sendsBeforeShutdown, "late owner check dispatched after shutdown");

// A new process has none of the extension's classification caches.
const freshContext = spawnSync(process.execPath, ["--input-type=module", "-e", `
  import assert from 'node:assert/strict';
  import { registerFeishuNativeChannel, classifyFeishuMessage } from './.pi/extensions/lib/fm-feishu-native-channel.ts';
  const message = JSON.parse(process.argv[2]);
  const handlers = new Map();
  registerFeishuNativeChannel({ on(name, handler) { handlers.set(name, handler); }, events: { on() { return () => {}; } } });
  assert.equal(classifyFeishuMessage(message), undefined);
  assert.deepEqual(handlers.get('context')({ messages: [message] }).messages, []);
`, home, JSON.stringify(deliveredMessage)], { encoding: "utf8", timeout: 10000 });
assert.equal(freshContext.status, 0, freshContext.stderr);

function stateOnlyHome(name) {
  const target = join(process.env.FM_HOME, name);
  const session = join(target, "session.jsonl");
  mkdirSync(target, { recursive: true });
  writeFileSync(session, `{"type":"session","version":3,"id":"${sessionId}","cwd":"${target}"}\n`);
  createPairing(target, { appIdFingerprint: pairing.app_id_fingerprint, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
  const localBinding = bindSession(target, { sessionId, sessionFile: session, sessionCwd: target, headerId: sessionId, headerCwd: target, outboundAfterEntryId: null });
  return { target, localBinding };
}
const emptyFixture = stateOnlyHome("empty");
const emptyResult = cleanupProcessedFeishuBodies(emptyFixture.target, { nowMs: clock });
assert.equal(emptyResult.filesBefore, 0, "idle empty cleanup reported a message file");
assert.equal(emptyResult.removedFiles, 0, "idle empty cleanup removed a record");
const supersededFixture = stateOnlyHome("superseded");
const superseded = publishFeishuInbound(supersededFixture.target, inbound("superseded", "superseded inbound body"));
convergeConfiguredSession(supersededFixture.target, {
  appIdFingerprint: `sha256:${"2".repeat(64)}`,
  allowedUser: "ou_replacement1234",
  allowedChat: "oc_replacement1234",
}, {
  sessionId,
  sessionFile: join(supersededFixture.target, "session.jsonl"),
  sessionCwd: supersededFixture.target,
  headerId: sessionId,
  headerCwd: supersededFixture.target,
  outboundAfterEntryId: null,
});
const supersededResult = cleanupProcessedFeishuBodies(supersededFixture.target, { nowMs: clock });
assert.equal(supersededResult.removedFiles, 0, "superseded inbound body crossed the processed boundary");
const retainedSuperseded = findInboundByDeliveryRef(supersededFixture.target, superseded.deliveryRef);
assert.equal(retainedSuperseded.content[0].text, "superseded inbound body", "superseded inbound body was removed");
assert(!Object.hasOwn(retainedSuperseded, "body_removed_at"), "superseded inbound gained a cleanup marker");
for (const state of ["sending", "retryable"]) {
  const fixture = stateOnlyHome(state);
  registerAssistantOutbound(fixture.target, {
    text: `${state} outbound body`, assistantEntryId: state === "sending" ? "20000001" : "20000002", sessionOrder: 1,
    sessionEntryTimestamp: new Date(clock).toISOString(), sessionId, bindingGeneration: fixture.localBinding.generation,
  });
  const active = claimNextOutbound(fixture.target, { nowMs: clock });
  if (state === "retryable") failOutboundAttempt(fixture.target, active, "retry later", { retryAfterMs: 1000, nowMs: clock });
  const result = cleanupProcessedFeishuBodies(fixture.target, { nowMs: clock });
  assert.equal(result.removedFiles, 0, `${state} outbound body crossed the processed boundary`);
  const record = JSON.parse(readFileSync(join(pathsForHome(fixture.target).outbox, readdirSync(pathsForHome(fixture.target).outbox)[0]), "utf8"));
  assert.equal(record.text, `${state} outbound body`, `${state} outbound body was removed`);
}

const originalReaddirForCleanup = fs.readdirSync;
fs.readdirSync = (path, ...args) => {
  assert(![paths.outboundReceipts, paths.inboundEventIds].includes(String(path)), "periodic cleanup enumerated retained idempotency history");
  return originalReaddirForCleanup(path, ...args);
};
syncBuiltinESMExports();
try { cleanupProcessedFeishuBodies(home); }
finally { fs.readdirSync = originalReaddirForCleanup; syncBuiltinESMExports(); }

// Fault injection changes only disposable filesystem operations, never owner code.
// Every observed cleanup publication/unlink boundary is replayed independently.
function outboundInput(localBinding) {
  return { text: "fault fixture outbound", assistantEntryId: "abcdef01", sessionOrder: 1,
    sessionEntryTimestamp: new Date(clock).toISOString(), sessionId, bindingGeneration: localBinding.generation };
}
function readyFixture(name) {
  const fixture = stateOnlyHome(name);
  const p = pathsForHome(fixture.target);
  const event = publishFeishuInbound(fixture.target, inbound(name, "fault fixture inbound"));
  const fence = { sessionId, bindingId: fixture.localBinding.binding_id, bindingGeneration: fixture.localBinding.generation };
  offerFeishuIngress(fixture.target, event.deliveryRef, fence);
  reconcileFeishuIngress(fixture.target, [{ deliveryRef: event.deliveryRef, sessionId, bindingGeneration: fence.bindingGeneration }], fence);
  const input = outboundInput(fixture.localBinding);
  registerAssistantOutbound(fixture.target, input);
  const claim = claimNextOutbound(fixture.target, { nowMs: clock });
  receiptOutbound(fixture.target, claim, { messageId: "om_faultReceipt1234", chatId: "oc_chat1234" });
  return { ...fixture, p, event, fence, input, claim };
}
const originalRename = fs.renameSync;
const originalUnlink = fs.unlinkSync;
const referenceFixture = readyFixture("crashreference");
const boundaries = [];
function recordMutation(kind, path) {
  const relative = String(path).slice(referenceFixture.p.stateRoot.length);
  if (relative.startsWith("/.") || relative === "/inbound-pending-count") return;
  boundaries.push({ kind, relative });
}
fs.renameSync = (from, to) => { const value = originalRename(from, to); recordMutation("rename", to); return value; };
fs.unlinkSync = (path) => { const value = originalUnlink(path); recordMutation("unlink", path); return value; };
syncBuiltinESMExports();
cleanupProcessedFeishuBodies(referenceFixture.target);
fs.renameSync = originalRename; fs.unlinkSync = originalUnlink; syncBuiltinESMExports();
assert(boundaries.length >= 8, "fault matrix missed cleanup publications/unlinks");
for (let cut = 0; cut < boundaries.length; cut += 1) {
  const fixture = readyFixture(`crash${cut}`);
  let seen = 0;
  let interrupted = false;
  const interrupt = (kind, path) => {
    const relative = String(path).slice(fixture.p.stateRoot.length);
    if (relative.startsWith("/.") || relative === "/inbound-pending-count") return;
    if (seen++ === cut) { interrupted = true; throw new Error("injected cleanup interruption"); }
  };
  fs.renameSync = (from, to) => { const value = originalRename(from, to); interrupt("rename", to); return value; };
  fs.unlinkSync = (path) => { const value = originalUnlink(path); interrupt("unlink", path); return value; };
  syncBuiltinESMExports();
  try { cleanupProcessedFeishuBodies(fixture.target); }
  catch (error) { assert.match(error.message, /injected cleanup interruption/); }
  finally { fs.renameSync = originalRename; fs.unlinkSync = originalUnlink; syncBuiltinESMExports(); }
  assert(interrupted, `cleanup cut ${cut} was not reached`);
  repairInboundLedgers(fixture.target);
  repairOutboundState(fixture.target);
  cleanupProcessedFeishuBodies(fixture.target);
  for (const key of ["inbox", "inboundLedger", "inboundDeliveryMap", "inboundPending", "outbox", "outboundLedger", "outboundPending"]) assert.equal(readdirSync(fixture.p[key]).length, 0, `${key} survived cut ${cut}`);
  assert.equal(pendingFeishuIngress(fixture.target, fixture.fence).length, 0);
  assert.equal(registerAssistantOutbound(fixture.target, fixture.input).status, "duplicate");
  assert.equal(persistAssistantOutboundIntent(fixture.target, fixture.input).status, "duplicate");
  assert.throws(() => registerAssistantOutbound(fixture.target, { ...fixture.input, text: "conflicting text" }), /conflicts/);
  assert.equal(receiptOutbound(fixture.target, fixture.claim, { messageId: "om_faultReceipt1234", chatId: "oc_chat1234" }), false);
  assert.equal(claimNextOutbound(fixture.target), undefined);
  assert.equal(publishFeishuInbound(fixture.target, { ...inbound(`crash${cut}`, "fault fixture inbound"), event_id: `new_${cut}` }).status, "duplicate");
}
console.log(`evidence - interrupted cleanup recovery boundaries=${boundaries.length}`);

for (const owner of ["inbox", "inbound-ledger", "inbound-event-ids", "inbound-pending"]) {
  const fixture = stateOnlyHome(`publish-${owner}`);
  let interrupted = false;
  fs.renameSync = (from, to) => {
    const value = originalRename(from, to);
    if (!interrupted && String(to).includes(`/${owner}/`)) { interrupted = true; throw new Error("injected publication interruption"); }
    return value;
  };
  syncBuiltinESMExports();
  try { publishFeishuInbound(fixture.target, inbound("publication", "pending publication")); }
  catch (error) { assert.match(error.message, /injected publication interruption/); }
  finally { fs.renameSync = originalRename; syncBuiltinESMExports(); }
  assert(interrupted);
  const fence = { sessionId, bindingId: fixture.localBinding.binding_id, bindingGeneration: fixture.localBinding.generation };
  const candidates = pendingFeishuIngress(fixture.target, fence);
  assert.equal(candidates.length, 1, `${owner} interruption lost pending work`);
  assert.equal(candidates[0].event.content[0].text, "pending publication");
  assert.equal(publishFeishuInbound(fixture.target, inbound("publication", "pending publication")).status, "duplicate");
}
// Crash after durable ack but before removing the pending index.
const ackFixture = stateOnlyHome("ack-interruption");
const ackEvent = publishFeishuInbound(ackFixture.target, inbound("ack", "acked once"));
const ackFence = { sessionId, bindingId: ackFixture.localBinding.binding_id, bindingGeneration: ackFixture.localBinding.generation };
offerFeishuIngress(ackFixture.target, ackEvent.deliveryRef, ackFence);
fs.unlinkSync = (path) => { if (String(path).includes("/inbound-pending/")) throw new Error("injected ack interruption"); return originalUnlink(path); };
syncBuiltinESMExports();
assert.throws(() => reconcileFeishuIngress(ackFixture.target, [{ deliveryRef: ackEvent.deliveryRef, sessionId, bindingGeneration: ackFence.bindingGeneration }], ackFence), /injected ack/);
fs.unlinkSync = originalUnlink; syncBuiltinESMExports();
assert.equal(pendingFeishuIngress(ackFixture.target, ackFence).length, 0, "interrupted ack replayed input");
cleanupProcessedFeishuBodies(ackFixture.target);
assert.equal(readdirSync(pathsForHome(ackFixture.target).inboundPending).length, 0);

// Complete external receipt persisted, ledger update interrupted: recover it
// locally rather than issuing another external send.
const receiptFixture = stateOnlyHome("receipt-interruption");
const receiptInput = outboundInput(receiptFixture.localBinding);
registerAssistantOutbound(receiptFixture.target, receiptInput);
const receiptClaim = claimNextOutbound(receiptFixture.target, { nowMs: clock });
fs.renameSync = (from, to) => {
  const value = originalRename(from, to);
  if (String(to).includes("/outbound-receipts/")) throw new Error("injected receipt interruption");
  return value;
};
syncBuiltinESMExports();
assert.throws(() => receiptOutbound(receiptFixture.target, receiptClaim, { messageId: "om_interruptedReceipt1234", chatId: "oc_chat1234" }), /injected receipt/);
fs.renameSync = originalRename; syncBuiltinESMExports();
cleanupProcessedFeishuBodies(receiptFixture.target);
assert.equal(claimNextOutbound(receiptFixture.target), undefined);
assert.equal(registerAssistantOutbound(receiptFixture.target, receiptInput).status, "duplicate");
const receiptPaths = pathsForHome(receiptFixture.target);
assert.equal(readdirSync(receiptPaths.outboundLedger).length, 0);
assert.deepEqual(JSON.parse(readFileSync(join(receiptPaths.outboundReceipts, receiptClaim.filename))).message_ids, ["om_interruptedReceipt1234"]);

// Separate processes publish/ack and collect against the same disposable home.
const concurrent = stateOnlyHome("concurrent");
const concurrentPaths = pathsForHome(concurrent.target);
const concurrentFence = { sessionId, bindingId: concurrent.localBinding.binding_id, bindingGeneration: concurrent.localBinding.generation };
const childProgram = `
  import * as state from ${JSON.stringify(new URL("./bin/fm-feishu-state.mjs", `file://${process.cwd()}/`).href)};
  const home = process.argv[1], fence = JSON.parse(process.argv[2]);
  for (let i = 0; i < 16; i++) {
    const raw = { event_id: 'evt_concurrent' + i, message_id: 'om_concurrent' + i + '1234', sender_id: 'ou_captain1234', sender_type: 'user', chat_id: 'oc_chat1234', chat_type: 'p2p', message_type: 'text', content: 'concurrent pending ' + i, create_time: '1' };
    const event = state.publishFeishuInbound(home, raw);
    if (i % 2 === 0) {
      state.offerFeishuIngress(home, event.deliveryRef, fence);
      state.reconcileFeishuIngress(home, [{ deliveryRef: event.deliveryRef, sessionId: fence.sessionId, bindingGeneration: fence.bindingGeneration }], fence);
    }
    await new Promise(resolve => setTimeout(resolve, 2));
  }
`;
const concurrentChild = spawn(process.execPath, ["--input-type=module", "-e", childProgram, concurrent.target, JSON.stringify(concurrentFence)], { stdio: ["ignore", "pipe", "pipe"] });
let childOutput = "", childDone = false;
concurrentChild.stderr.on("data", data => { childOutput += data; });
const childResult = new Promise(resolve => concurrentChild.on("exit", code => { childDone = true; resolve(code); }));
while (!childDone) {
  cleanupProcessedFeishuBodies(concurrent.target);
  await new Promise(resolve => setTimeout(resolve, 5));
}
assert.equal(await childResult, 0, childOutput);
cleanupProcessedFeishuBodies(concurrent.target);
const concurrentPending = pendingFeishuIngress(concurrent.target, concurrentFence);
assert.equal(concurrentPending.length, 8, "concurrent cleanup lost or duplicated pending publications");
assert.equal(new Set(concurrentPending.map(item => item.event.message_id)).size, 8);
for (const key of ["inbox", "inboundLedger", "inboundDeliveryMap", "inboundPending"]) assert.equal(readdirSync(concurrentPaths[key]).length, 8);
console.log("evidence - concurrent publication/ack/cleanup retained 8 pending and retired 8 delivered records");

// Native unsigned text is never dropped merely for an unknown source marker.
const forgedNative = { role: "user", content: "\u2063FIRSTMATE_FEISHU: v1 ref=in_000000000000000000000000 g=1\nnew native request" };
assert.deepEqual((await emit(resumedPi, "context", { messages: [forgedNative] }, ctx))[0].messages, [forgedNative]);
const forgedCustom = { ...deliveredMessage, content: "untrusted", details: { ...deliveredMessage.details, deliveryRef: "in_000000000000000000000000" } };
assert.deepEqual((await emit(resumedPi, "context", { messages: [forgedCustom] }, ctx))[0].messages, []);

console.log("evidence - message JSON files before=7 after=5; legacy processed files before=7 after=5");
console.log("ok - five-second Feishu cleanup unlinks only receipt-proven message files and preserves all unfinished work");
JS

# The same public ingress calls run with fixed work and varied processed history.
PERF_ROOT="$TMP_ROOT/performance" node --input-type=module <<'PERF'
import assert from "node:assert/strict";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { createHash } from "node:crypto";
import { join } from "node:path";
const state = await import(process.env.FM_FEISHU_PERF_MODULE || "./bin/fm-feishu-state.mjs");
const sha = value => createHash("sha256").update(value).digest("hex");
const write = (path, value) => fs.writeFileSync(path, JSON.stringify(value), { mode: 0o600 });
const originalRead = fs.readFileSync;
const originalReaddir = fs.readdirSync;
const originalParse = JSON.parse;
const measure = callback => {
  const ops = { directories: 0, entries: 0, reads: 0, parses: 0 };
  fs.readFileSync = (...args) => { ops.reads++; return originalRead(...args); };
  fs.readdirSync = (...args) => { ops.directories++; const entries = originalReaddir(...args); ops.entries += entries.length; return entries; };
  JSON.parse = (...args) => { ops.parses++; return originalParse(...args); };
  syncBuiltinESMExports();
  const start = performance.now(); const cpu = process.cpuUsage();
  try { callback(); }
  finally { fs.readFileSync = originalRead; fs.readdirSync = originalReaddir; JSON.parse = originalParse; syncBuiltinESMExports(); }
  const usage = process.cpuUsage(cpu);
  return { ops, wallMs: +(performance.now() - start).toFixed(2), cpuMs: +((usage.user + usage.system) / 1000).toFixed(2) };
};
const rows = [];
for (const count of [0, 40, 1500, 3000]) {
  const home = join(process.env.PERF_ROOT, String(count));
  fs.mkdirSync(home, { recursive: true });
  const sessionId = "12345678-1234-1234-1234-123456789abc";
  const sessionFile = join(home, "session.jsonl");
  write(sessionFile, { type: "session", version: 3, id: sessionId, cwd: home });
  const pairing = state.createPairing(home, { appIdFingerprint: `sha256:${"1".repeat(64)}`, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
  const binding = state.bindSession(home, { sessionId, sessionFile, sessionCwd: home, headerId: sessionId, headerCwd: home, outboundAfterEntryId: null });
  const paths = state.pathsForHome(home);
  const fence = { sessionId, bindingId: binding.binding_id, bindingGeneration: binding.generation };
  const raw = suffix => ({ event_id: `evt_${suffix}`, message_id: `om_${suffix}1234`, sender_id: "ou_captain1234", sender_type: "user", chat_id: "oc_chat1234", chat_type: "p2p", message_type: "text", content: "fixture", create_time: "1" });
  // Public publication defines the fixture schema; copies vary only identity.
  const seed = state.publishFeishuInbound(home, raw("seed"));
  state.offerFeishuIngress(home, seed.deliveryRef, fence);
  state.reconcileFeishuIngress(home, [{ deliveryRef: seed.deliveryRef, sessionId, bindingGeneration: binding.generation }], fence);
  const seedName = sha(raw("seed").message_id) + ".json";
  const event = JSON.parse(fs.readFileSync(join(paths.inbox, seedName), "utf8"));
  const ledger = JSON.parse(fs.readFileSync(join(paths.inboundLedger, seedName), "utf8"));
  const map = JSON.parse(fs.readFileSync(join(paths.inboundDeliveryMap, sha(seed.deliveryRef) + ".json"), "utf8"));
  for (const [dir, name] of [[paths.inbox, seedName], [paths.inboundLedger, seedName], [paths.inboundDeliveryMap, sha(seed.deliveryRef) + ".json"]]) fs.unlinkSync(join(dir, name));
  for (let i = 0; i < count; i++) {
    const messageId = `om_history${i}1234`, eventId = `evt_history${i}`;
    const ref = "in_" + sha(`${pairing.home_id}\0${messageId}`).slice(0, 24);
    const name = sha(messageId) + ".json";
    write(join(paths.inbox, name), { ...event, message_id: messageId, event_ids: [eventId], delivery_ref: ref, ingress_seq: i + 1 });
    write(join(paths.inboundLedger, name), { ...ledger, message_id: messageId, delivery_ref: ref, ingress_seq: i + 1 });
    write(join(paths.inboundDeliveryMap, sha(ref) + ".json"), { ...map, message_id: messageId, filename: name, delivery_ref: ref });
  }
  state.repairInboundLedgers(home); // startup boundary outside measurement
  const idle = measure(() => { for (let i = 0; i < 5; i++) assert.equal(state.pendingFeishuIngress(home, fence).length, 0); });
  const pending = state.publishFeishuInbound(home, raw("pending"));
  const work = measure(() => {
    assert.equal(state.pendingFeishuIngress(home, fence).length, 1);
    assert(state.offerFeishuIngress(home, pending.deliveryRef, fence));
    state.reconcileFeishuIngress(home, [{ deliveryRef: pending.deliveryRef, sessionId, bindingGeneration: binding.generation }], fence);
    assert.equal(state.pendingFeishuIngress(home, fence).length, 0);
  });
  state.cleanupProcessedFeishuBodies(home);
  if (!process.env.FM_FEISHU_PERF_BASELINE) for (const key of ["inbox", "inboundLedger", "inboundDeliveryMap"]) assert.equal(fs.readdirSync(paths[key]).length, 0);
  const cleanedIdle = measure(() => { for (let i = 0; i < 5; i++) state.pendingFeishuIngress(home, fence); state.cleanupProcessedFeishuBodies(home); });
  rows.push({ history: count, idle, work, cleanedIdle });
  console.log("evidence - ingress scale " + JSON.stringify(rows.at(-1)));
}
if (!process.env.FM_FEISHU_PERF_BASELINE) {
  for (const row of rows.slice(1)) for (const phase of ["idle", "work", "cleanedIdle"]) assert.deepEqual(row[phase].ops, rows[0][phase].ops, `${phase} scaled with processed history=${row.history}`);
}
console.log(process.env.FM_FEISHU_PERF_BASELINE ? "evidence - baseline measurement complete" : "ok - ingress reads/parses/enumeration depend only on pending work; retained identities are point lookups");
PERF
