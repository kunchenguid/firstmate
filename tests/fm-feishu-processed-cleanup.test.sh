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
  pendingFeishuIngress,
  publishFeishuInbound,
  receiptOutbound,
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
assert.equal(messageFileCount(), 7, "before-count fixture did not contain every inbound and outbound message file");
clock += 4999;
await new Promise((resolve) => setTimeout(resolve, 30));
assert.equal(messageFileCount(), 7, "processed message cleanup ran before the five-second boundary");
clock += 1;
await waitFor(() => messageFileCount() === 5, "five-second processed-message cleanup");
assert.equal(messageFileCount(), 5, "after-count did not remove exactly the two safely processed message files");
assert(!existsSync(deliveredInboundPath), "delivered inbound JSON file survived cleanup");
assert(!existsSync(postedOutboundPath), "posted outbound JSON file survived cleanup");

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
const { text_hash: _newProcessedIdentity, ...legacyPostedLedger } = JSON.parse(readFileSync(postedLedgerPath, "utf8"));
writeFileSync(postedLedgerPath, `${JSON.stringify(legacyPostedLedger, null, 2)}\n`, { mode: 0o600 });
assert.equal(messageFileCount(), 7, "legacy processed empty-body fixtures were not restored as message files");
clock += 4999;
await new Promise((resolve) => setTimeout(resolve, 30));
assert.equal(messageFileCount(), 7, "legacy processed message cleanup ran before its five-second boundary");
clock += 1;
await waitFor(() => messageFileCount() === 5, "five-second legacy processed-message cleanup");
assert(!existsSync(deliveredInboundPath), "legacy processed inbound JSON file survived cleanup");
assert(!existsSync(postedOutboundPath), "legacy processed outbound JSON file survived cleanup");
assert.equal(JSON.parse(readFileSync(postedLedgerPath, "utf8")).text_hash, postedTextHash, "legacy processed outbound cleanup did not retain the minimal no-replay hash");

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
assert.equal(posted.eventId, JSON.parse(readFileSync(postedLedgerPath, "utf8")).event_id, "processed outbound ledger changed stable effect identity");
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
await emit(resumedPi, "session_shutdown", { reason: "fixture-complete" }, ctx);

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

console.log("evidence - message JSON files before=7 after=5; legacy processed files before=7 after=5");
console.log("ok - five-second Feishu cleanup unlinks only receipt-proven message files and preserves all unfinished work");
JS
