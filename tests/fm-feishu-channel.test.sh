#!/usr/bin/env bash
# Behavioral regression for the opt-in Feishu current-Pi channel.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-feishu-channel)
HOME_DIR="$TMP_ROOT/home"
SESSION_DIR="$TMP_ROOT/session"
SESSION_FILE="$SESSION_DIR/current.jsonl"
LOCK_SCRIPT="$TMP_ROOT/lock-status.sh"
SID=12345678-1234-1234-1234-123456789abc
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$SESSION_DIR"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$SESSION_DIR" > "$SESSION_FILE"
printf 'owned\n' > "$HOME_DIR/lock-mode"
cat > "$LOCK_SCRIPT" <<'SH'
#!/usr/bin/env bash
mode=$(cat "${FM_HOME:?}/lock-mode" 2>/dev/null || printf other)
printf '%s\n' "$mode"
[ "$mode" = owned ]
SH
chmod +x "$LOCK_SCRIPT"

FM_HOME="$HOME_DIR" \
FM_ROOT_OVERRIDE="$ROOT" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
SESSION_FILE="$SESSION_FILE" \
SESSION_DIR="$SESSION_DIR" \
SID="$SID" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ackIngress,
  bindPendingDecisionToOutbound,
  bindSession,
  claimNextOutbound,
  claimPendingDecisionForOutbound,
  createPairing,
  deterministicChunks,
  disablePairing,
  findInboundByDeliveryRef,
  ingressCounts,
  publishFeishuInbound,
  receiptOutbound,
  registerAssistantOutbound,
  registerPendingDecision,
  statusSummary,
  writeTransportHealth,
} from "./bin/fm-feishu-state.mjs";
import {
  encodeFirstmateIngress,
  feishuSensitiveToolReason,
  parseFirstmateIngressMarker,
  registerFirstmateIngressCoordinator,
  renderFirstmateSourceBadge,
  submitFirstmateInternalInput,
} from "./.pi/extensions/lib/fm-primary-ingress.ts";

const home = process.env.FM_HOME;
const sessionId = process.env.SID;
const sessionFile = process.env.SESSION_FILE;
const sessionCwd = process.env.SESSION_DIR;
const pairing = createPairing(home, {
  botOpenId: "ou_bot1234",
  allowedUser: "ou_captain1234",
  allowedChat: "oc_chat1234",
});
const binding = bindSession(home, {
  sessionId,
  sessionFile,
  sessionCwd,
  headerId: sessionId,
  headerCwd: sessionCwd,
});
writeTransportHealth(home, { phase: "healthy", healthy: true });

function context(id = sessionId, file = sessionFile, cwd = sessionCwd) {
  const entries = [];
  const notifications = [];
  const statuses = new Map();
  let idle = true;
  return {
    entries,
    notifications,
    statuses,
    setIdle(value) { idle = value; },
    ctx: {
      mode: "tui",
      hasUI: true,
      cwd,
      isProjectTrusted: () => true,
      isIdle: () => idle,
      sessionManager: {
        getSessionFile: () => file,
        getSessionId: () => id,
        getHeader: () => ({ id, cwd }),
        getEntries: () => entries,
      },
      ui: {
        notify(message, level) { notifications.push({ message, level }); },
        setStatus(key, value) { statuses.set(key, value); },
      },
    },
  };
}

function fakePi() {
  const handlers = new Map();
  const sends = [];
  const entries = [];
  const transforms = [];
  const pi = {
    handlers,
    sends,
    entries,
    transforms,
    on(event, handler) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
    registerMarkdownTransformer(transformer) { transforms.push(transformer); },
    sendUserMessage(content, options) { sends.push({ content, options }); },
    appendEntry(customType, data) { entries.push({ customType, data }); },
  };
  return pi;
}

async function emit(pi, name, event, ctx) {
  const results = [];
  for (const handler of pi.handlers.get(name) ?? []) results.push(await handler({ type: name, ...event }, ctx));
  return results;
}

let entryCounter = 0;
async function accept(pi, session, sent) {
  const content = Array.isArray(sent.content) ? sent.content : [{ type: "text", text: sent.content }];
  const message = { role: "user", content, timestamp: Date.now() };
  const id = `entry${String(++entryCounter).padStart(3, "0")}`;
  session.entries.push({ type: "message", id, parentId: null, message });
  await emit(pi, "message_start", { message }, session.ctx);
  await emit(pi, "message_end", { message }, session.ctx);
  await new Promise((resolve) => setTimeout(resolve, 20));
  return id;
}

async function settle(pi, session, text) {
  const partial = { role: "assistant", content: [{ type: "text", text: "partial must stay private" }] };
  await emit(pi, "message_update", { message: partial, assistantMessageEvent: { type: "text_delta", delta: "partial" } }, session.ctx);
  const message = { role: "assistant", content: [{ type: "text", text }], stopReason: "stop", timestamp: Date.now() };
  await emit(pi, "turn_end", { turnIndex: 0, message, toolResults: [] }, session.ctx);
  await emit(pi, "agent_settled", {}, session.ctx);
}

const session = context();
const pi = fakePi();
registerFirstmateIngressCoordinator(pi);
await emit(pi, "session_start", { reason: "startup" }, session.ctx);
assert.equal(pi.transforms.length, 1, "source badge transformer was not registered");

const remoteA = {
  type: "im.message.receive_v1",
  event_id: "evt_a",
  message_id: "om_remoteA1234",
  sender_id: "ou_captain1234",
  sender_type: "user",
  chat_id: "oc_chat1234",
  chat_type: "p2p",
  message_type: "text",
  content: "/new is ordinary remote text",
  create_time: "1",
};
assert.equal(publishFeishuInbound(home, remoteA).status, "published");
assert.equal(publishFeishuInbound(home, { ...remoteA, event_id: "evt_duplicate" }).status, "duplicate");
assert.equal(
  publishFeishuInbound(home, { ...remoteA, message_id: "om_sameEvent1234" }).status,
  "duplicate",
  "event_id dedupe accepted a second message identity",
);
assert.equal(
  publishFeishuInbound(home, { ...remoteA, event_id: "evt_pressure", message_id: "om_pressure1234" }, { maxPendingInbound: 1 }).reason,
  "resource-pressure",
  "event-storm queue threshold did not stop additional durable ingress",
);
assert.equal(
  publishFeishuInbound(
    home,
    { ...remoteA, event_id: "evt_disk", message_id: "om_diskFloor1234" },
    { maxPendingInbound: 9999, minFreeBytes: Number.MAX_SAFE_INTEGER },
  ).reason,
  "resource-pressure",
  "disk-space floor did not stop additional durable ingress",
);
const inputResults = await emit(pi, "input", {
  text: "local steer",
  images: [],
  source: "interactive",
  streamingBehavior: "steer",
}, session.ctx);
assert(inputResults.some((result) => result?.action === "handled"), "local TUI text bypassed the shared ingress coordinator");
await new Promise((resolve) => setTimeout(resolve, 40));
assert.equal(pi.sends.length, 1, "single-flight accepted more than one simultaneous input");
assert.equal(parseFirstmateIngressMarker(pi.sends[0].content)?.source, "feishu");
assert.equal(pi.sends[0].options, undefined, "idle Feishu input was incorrectly queued as busy");
assert(pi.sends[0].content.endsWith("/new is ordinary remote text"), "remote slash-like text was rewritten or invoked as a command");
assert(!pi.sends[0].content.includes("ou_captain1234") && !pi.sends[0].content.includes("oc_chat1234"), "stable Feishu identifiers leaked into model context");
const badge = renderFirstmateSourceBadge(pi.sends[0].content, "user");
assert(badge.includes("Feishu - authorized P2P") && !badge.includes("FIRSTMATE_INGRESS"), "TUI source badge did not hide the private marker");
session.setIdle(false);
await accept(pi, session, pi.sends[0]);
await new Promise((resolve) => setTimeout(resolve, 40));
assert.equal(pi.sends.length, 2, "second ordered input was not submitted after first acceptance");
assert.equal(parseFirstmateIngressMarker(pi.sends[1].content)?.source, "tui");
assert.equal(pi.sends[1].options?.deliverAs, "steer", "busy local Enter lost steer semantics");
await accept(pi, session, pi.sends[1]);
const followUpResults = await emit(pi, "input", {
  text: "local follow-up",
  images: [{ type: "image", data: "dGlueQ==", mimeType: "image/png" }],
  source: "interactive",
  streamingBehavior: "followUp",
}, session.ctx);
assert(followUpResults.some((result) => result?.action === "handled"));
await new Promise((resolve) => setTimeout(resolve, 40));
assert.equal(pi.sends[2].options?.deliverAs, "followUp", "busy local Alt+Enter lost follow-up semantics");
assert(Array.isArray(pi.sends[2].content) && pi.sends[2].content[1]?.data === "dGlueQ==", "local TUI image bypassed durable ordered ingress");
await accept(pi, session, pi.sends[2]);
assert.equal(ingressCounts(home).delivered, 3, "message_end persistence did not ACK all accepted inputs");

await settle(pi, session, "Final local response with https://example.test/complete/path");
let claim = claimNextOutbound(home);
assert(claim, "agent_settled did not register the final Assistant response");
assert.equal(claim.outbox.text, "Final local response with https://example.test/complete/path");
assert.equal(claim.outbox.reply_to_message_id, null, "local TUI response guessed a source reply");
assert(!claim.outbox.text.includes("partial must stay private"), "partial Assistant output entered the outbox");
receiptOutbound(home, claim, { messageId: "om_localOut1234", chatId: "oc_chat1234" });

const remoteB = { ...remoteA, event_id: "evt_b", message_id: "om_remoteB1234", content: "remote request", create_time: "2" };
publishFeishuInbound(home, remoteB);
await new Promise((resolve) => setTimeout(resolve, 320));
const remoteSend = pi.sends.at(-1);
assert.equal(parseFirstmateIngressMarker(remoteSend.content)?.source, "feishu");
assert.equal(remoteSend.options?.deliverAs, "followUp", "busy Feishu input did not default to followUp");
await accept(pi, session, remoteSend);
await settle(pi, session, "Direct final Feishu answer https://example.test/full");
claim = claimNextOutbound(home);
assert.equal(claim.outbox.reply_to_message_id, "om_remoteB1234", "Feishu-originated turn did not reply to its exact triggering message");
assert.equal(claim.outbox.text, "Direct final Feishu answer https://example.test/full", "direct Assistant output was summarized or rewritten");
receiptOutbound(home, claim, { messageId: "om_remoteOut1234", chatId: "oc_chat1234" });

const pendingBeforeSkips = statusSummary(home).outbound_pending;
await settle(pi, session, "Captain, shipshape.");
assert.equal(statusSummary(home).outbound_pending, pendingBeforeSkips, "exact routine response entered the outbox");
await settle(pi, session, "Authorization: Bearer fixed-secret-value-123456");
assert.equal(statusSummary(home).outbound_pending, pendingBeforeSkips, "secret-like final response was partially transmitted");
assert(pi.entries.some((entry) => entry.customType === "fm-feishu-local-alert"), "whole-message secret refusal did not raise one local durable alert");
const alertCount = pi.entries.length;
await settle(pi, session, "Authorization: Bearer fixed-secret-value-123456");
assert.equal(pi.entries.length, alertCount, "same secret refusal raised duplicate local alerts");

await submitFirstmateInternalInput(pi, "\u2063FIRSTMATE_OP: v1 watcher: internal only", "followUp");
await new Promise((resolve) => setTimeout(resolve, 40));
const internalSend = pi.sends.at(-1);
assert.equal(parseFirstmateIngressMarker(internalSend.content)?.source, "internal");
await accept(pi, session, internalSend);
await settle(pi, session, "Internal operational response");
assert.equal(statusSummary(home).outbound_pending, pendingBeforeSkips, "purely internal operational turn entered the outbox");

assert(feishuSensitiveToolReason("bash", { command: "bin/fm-pr-merge.sh task https://example.test/pr/1" }, "feishu")?.includes("local TUI"));
assert(feishuSensitiveToolReason("bash", { command: "git worktree remove isolated-copy" }, "feishu")?.includes("local TUI"));
assert(feishuSensitiveToolReason("bash", { command: "lark-cli config init --new" }, "feishu")?.includes("local TUI"));
assert.equal(feishuSensitiveToolReason("bash", { command: "printf safe" }, "feishu"), undefined);
assert.equal(feishuSensitiveToolReason("bash", { command: "bin/fm-pr-merge.sh x y" }, "tui"), undefined);

const chunks = deterministicChunks("alpha\n\nhttps://example.test/a/complete/url\n\nomega", 36);
assert.equal(chunks.join(""), "alpha\n\nhttps://example.test/a/complete/url\n\nomega");
assert(chunks.some((chunk) => chunk.includes("https://example.test/a/complete/url")), "deterministic chunking split a complete URL");
assert.throws(() => deterministicChunks(`https://example.test/${"x".repeat(100)}`, 20), /URL exceeds/);
const oversizedOutbound = registerAssistantOutbound(home, {
  text: "z".repeat(101),
  source: "tui",
  sourceRef: "in_resource00000000000000",
  sessionId,
  bindingGeneration: binding.generation,
  maxOutboundBytes: 100,
});
assert.equal(oversizedOutbound.status, "resource-refused", "outbound resource cap accepted oversized final text");

for (const [label, event, reason] of [
  ["unauthorized-user", { ...remoteA, message_id: "om_baduser1234", sender_id: "ou_other1234" }, "unauthorized-user"],
  ["unauthorized-chat", { ...remoteA, message_id: "om_badchat1234", chat_id: "oc_other1234" }, "unauthorized-chat"],
  ["bot-self", { ...remoteA, message_id: "om_botself1234", sender_type: "bot", sender_id: pairing.bot_open_id }, "bot-or-self"],
  ["unsupported", { ...remoteA, message_id: "om_file1234", message_type: "file", content: "file placeholder" }, "unsupported-type"],
  ["overlength", { ...remoteA, message_id: "om_long1234", content: "x".repeat(100) }, "overlength"],
]) {
  const result = publishFeishuInbound(home, { ...event, event_id: `evt_${label}` }, label === "overlength" ? { maxInboundBytes: 20 } : {});
  assert.equal(result.reason, reason, `${label} authorization result changed`);
}

// A reply closes only the exact mapped decision; an unrelated message carries no decision.
registerPendingDecision(home, { decisionRef: "dec-exact", decisionKey: "scope-choice", sessionId });
const decisionCandidate = claimPendingDecisionForOutbound(home, sessionId, binding.generation);
const decisionOut = registerAssistantOutbound(home, {
  text: "Choose A or B",
  source: "tui",
  sourceRef: "in_decision000000000000000",
  sessionId,
  bindingGeneration: binding.generation,
  decisionRef: "dec-exact",
  decisionKey: "scope-choice",
});
assert.equal(decisionOut.status, "registered");
bindPendingDecisionToOutbound(home, decisionCandidate, decisionOut.eventId);
claim = claimNextOutbound(home);
assert.equal(claim.outbox.decision_ref, "dec-exact");
receiptOutbound(home, claim, { messageId: "om_decisionOut1234", chatId: "oc_chat1234" });
const unrelated = publishFeishuInbound(home, { ...remoteA, event_id: "evt_unrelated", message_id: "om_unrelated1234", content: "A", reply_to: null, create_time: "3" });
assert.equal(unrelated.status, "published");
assert.equal(findInboundByDeliveryRef(home, unrelated.deliveryRef).decision_key, null, "unrelated message guessed an open decision");
assert.equal(findInboundByDeliveryRef(home, unrelated.deliveryRef).decision_reply, "unrelated", "unrelated chat text was not fenced from the open decision");
assert(encodeFirstmateIngress(findInboundByDeliveryRef(home, unrelated.deliveryRef)).includes("must not resolve any open decision"));
const exactReply = publishFeishuInbound(home, { ...remoteA, event_id: "evt_reply", message_id: "om_reply1234", content: "A", reply_to: "om_decisionOut1234", create_time: "4" });
assert.equal(exactReply.status, "published");
assert.equal(findInboundByDeliveryRef(home, exactReply.deliveryRef).decision_key, "scope-choice", "exact reply-to did not restore its decision key");
assert.equal(findInboundByDeliveryRef(home, exactReply.deliveryRef).decision_reply, "exact");

// Drain the two correlation fixtures before isolating the crash boundary.
for (let count = 0; count < 2; count += 1) {
  await new Promise((resolve) => setTimeout(resolve, 320));
  const pendingSend = pi.sends.at(-1);
  const marker = parseFirstmateIngressMarker(pendingSend.content);
  const event = marker && findInboundByDeliveryRef(home, marker.deliveryRef);
  if (event && ingressCounts(home).dispatching > 0) await accept(pi, session, pendingSend);
}

// Crash after Pi persistence but before adapter ACK: exact-session restart scans the marker and does not resubmit.
const crashEvent = { ...remoteA, event_id: "evt_crash", message_id: "om_crash1234", content: "crash boundary", create_time: "5" };
publishFeishuInbound(home, crashEvent);
await new Promise((resolve) => setTimeout(resolve, 320));
const crashSend = pi.sends.at(-1);
const crashMarker = parseFirstmateIngressMarker(crashSend.content);
assert(crashMarker, "crash fixture was not submitted");
const crashMessage = { role: "user", content: [{ type: "text", text: crashSend.content }], timestamp: Date.now() };
session.entries.push({ type: "message", id: "crashentry", parentId: null, message: crashMessage });
await emit(pi, "session_shutdown", { reason: "reload" }, session.ctx);
const resumedPi = fakePi();
registerFirstmateIngressCoordinator(resumedPi);
await emit(resumedPi, "session_start", { reason: "reload" }, session.ctx);
await new Promise((resolve) => setTimeout(resolve, 60));
assert.equal(resumedPi.sends.length, 0, "exact-session crash recovery duplicated a persisted user turn");
assert(ingressCounts(home).delivered >= 3, "session scan did not repair the missing ingress ACK");

// A wrong /new or forked session suspends stale callbacks even if Pi switches without first emitting shutdown.
const wrongId = "abcdefab-1234-1234-1234-abcdefabcdef";
const wrongFile = join(sessionCwd, "wrong.jsonl");
writeFileSync(wrongFile, `${JSON.stringify({ type: "session", version: 3, id: wrongId, cwd: sessionCwd })}\n`);
const wrongSession = context(wrongId, wrongFile, sessionCwd);
const resumedSendCount = resumedPi.sends.length;
await emit(resumedPi, "session_start", { reason: "new" }, wrongSession.ctx);
await new Promise((resolve) => setTimeout(resolve, 20));
assert.equal(resumedPi.sends.length, resumedSendCount, "the prior Pi session retained a stale ingress callback after /new");
await emit(resumedPi, "session_shutdown", { reason: "new" }, wrongSession.ctx);
const wrongPi = fakePi();
registerFirstmateIngressCoordinator(wrongPi);
await emit(wrongPi, "session_start", { reason: "new" }, wrongSession.ctx);
publishFeishuInbound(home, { ...remoteA, event_id: "evt_wrong", message_id: "om_wrong1234", content: "must wait", create_time: "6" });
await new Promise((resolve) => setTimeout(resolve, 60));
assert.equal(wrongPi.sends.length, 0, "wrong-session /new inherited the old Feishu binding");
const rebound = bindSession(home, {
  sessionId: wrongId,
  sessionFile: wrongFile,
  sessionCwd,
  headerId: wrongId,
  headerCwd: sessionCwd,
}, { rebind: true });
assert.equal(rebound.generation, binding.generation + 1, "explicit rebind did not increment generation");
const reboundPi = fakePi();
registerFirstmateIngressCoordinator(reboundPi);
await emit(reboundPi, "session_start", { reason: "reload" }, wrongSession.ctx);
writeTransportHealth(home, { phase: "healthy", healthy: true });
await new Promise((resolve) => setTimeout(resolve, 80));
assert(reboundPi.sends.length >= 1, "explicit local rebind did not retarget pending Feishu input");

// Lock loss fences callbacks and leaves newly received work durable.
writeFileSync(join(home, "lock-mode"), "other\n");
publishFeishuInbound(home, { ...remoteA, event_id: "evt_lock", message_id: "om_lockloss1234", content: "wait for owner", create_time: "7" });
const beforeLoss = reboundPi.sends.length;
await new Promise((resolve) => setTimeout(resolve, 350));
assert.equal(reboundPi.sends.length, beforeLoss, "session-lock loss still injected Feishu input");
assert(ingressCounts(home).pending >= 1, "session-lock loss discarded pending input");

// Pairing opt-out increments the fence and makes the feature inert.
writeFileSync(join(home, "lock-mode"), "owned\n");
const disabled = disablePairing(home);
assert.equal(disabled.changed, true);
assert.equal(statusSummary(home).disabled, true);

// Private state rejects a symlinked inbox instead of accepting a memory-only message.
const unsafeHome = join(home, "unsafe");
mkdirSync(join(unsafeHome, "data"), { recursive: true });
mkdirSync(join(unsafeHome, "state"), { recursive: true });
createPairing(unsafeHome, { botOpenId: "ou_bot1234", allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const unsafeSessionDir = join(unsafeHome, "session");
mkdirSync(unsafeSessionDir);
const unsafeFile = join(unsafeSessionDir, "s.jsonl");
writeFileSync(unsafeFile, `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: unsafeSessionDir })}\n`);
bindSession(unsafeHome, { sessionId, sessionFile: unsafeFile, sessionCwd: unsafeSessionDir, headerId: sessionId, headerCwd: unsafeSessionDir });
const inbox = join(unsafeHome, "state", "feishu", "inbox");
const backup = `${inbox}.real`;
await import("node:fs").then(({ renameSync, symlinkSync }) => { renameSync(inbox, backup); symlinkSync(backup, inbox); });
assert.throws(() => publishFeishuInbound(unsafeHome, remoteA), /unsafe Feishu state directory/);

console.log("ok - current-Pi Feishu ingress, session fences, direct Assistant egress, correlation, and safety state");
JS

DISABLED_BOOTSTRAP=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh)
printf '%s\n' "$DISABLED_BOOTSTRAP" | grep -q '^FEISHU:' \
  && fail "disabled Feishu pairing still changed bootstrap behavior"

BRIDGE_FIXTURE="$TMP_ROOT/bridge-fixture"
mkdir -p "$BRIDGE_FIXTURE/.pi/extensions/lib" "$BRIDGE_FIXTURE/bin" "$BRIDGE_FIXTURE/node_modules/@earendil-works" "$BRIDGE_FIXTURE/home/state"
cp "$ROOT/.pi/extensions/fm-primary-feishu-bridge.ts" "$BRIDGE_FIXTURE/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-primary-ingress.ts" "$BRIDGE_FIXTURE/.pi/extensions/lib/"
cp "$ROOT/bin/fm-feishu-state.d.mts" "$ROOT/bin/fm-feishu-state.mjs" "$BRIDGE_FIXTURE/bin/"
mkdir -p "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' > "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui/package.json"
cat > "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { addChild() {} }
export class Text {}
JS
printf '%s\n' '{"type":"module"}' > "$BRIDGE_FIXTURE/package.json"
FM_HOME="$BRIDGE_FIXTURE/home" \
FM_ROOT_OVERRIDE="$BRIDGE_FIXTURE" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
BRIDGE="$BRIDGE_FIXTURE/.pi/extensions/fm-primary-feishu-bridge.ts" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const commands = new Map();
const pi = {
  on() {},
  registerMarkdownTransformer() {},
  registerEntryRenderer() {},
  registerCommand(name, options) { commands.set(name, options); },
};
const bridge = await import(pathToFileURL(process.env.BRIDGE).href);
bridge.default(pi);
assert.deepEqual([...commands.keys()].sort(), [
  "fm-feishu-bind",
  "fm-feishu-disable",
  "fm-feishu-pair",
  "fm-feishu-rebind",
  "fm-feishu-status",
]);
console.log("ok - local Pi bridge registers only the explicit pairing and binding control surface");
JS

# The transport test uses one fake lark-cli executable.  It records argv, emits
# documented ready/drop behavior, supplies overlapping history, and returns
# deterministic send receipts.  Message text that looks like shell syntax must
# remain one inert argv value.
TRANSPORT_HOME="$TMP_ROOT/transport-home"
TRANSPORT_SESSION="$TMP_ROOT/transport-session"
TRANSPORT_FILE="$TRANSPORT_SESSION/current.jsonl"
FAKE_LARK="$TMP_ROOT/fake-lark-cli"
FAKE_LOG="$TMP_ROOT/fake-lark.log"
FAKE_COUNT="$TMP_ROOT/fake-consume-count"
TOUCH_SENTINEL="$TMP_ROOT/MUST_NOT_EXIST"
mkdir -p "$TRANSPORT_HOME/data" "$TRANSPORT_HOME/state" "$TRANSPORT_SESSION"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$TRANSPORT_SESSION" > "$TRANSPORT_FILE"
cat > "$FAKE_LARK" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'ARGV'
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "${FM_FAKE_LOG:?}"
case "${1:-} ${2:-}" in
  'whoami --as')
    printf '{"ok":true,"data":{"profile":"%s","open_id":"ou_bot1234","app_id":"cli_fake_app"}}\n' "${FM_FAKE_PROFILE:-default}"
    ;;
  'event consume')
    count=0
    [ ! -f "$FM_FAKE_COUNT" ] || count=$(cat "$FM_FAKE_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_COUNT"
    printf '[event] ready event_key=im.message.receive_v1\n' >&2
    if [ "$count" -eq 1 ] && [ "${FM_FAKE_DROP_ONCE:-0}" = 1 ]; then
      printf '%s\n' '{"type":"im.message.receive_v1","event_id":"evt_live_1","message_id":"om_liveOne1234","sender_id":"ou_captain1234","sender_type":"user","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"live one","create_time":"20"}'
      printf '[event] WARN dropped 2 event(s) due to backpressure\n' >&2
      exit 0
    fi
    printf '%s\n' '{"type":"im.message.receive_v1","event_id":"evt_live_2","message_id":"om_liveTwo1234","sender_id":"ou_captain1234","sender_type":"user","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"live two","create_time":"30"}'
    printf '%s\n' '{"type":"im.message.receive_v1","event_id":"evt_dup","message_id":"om_history1234","sender_id":"ou_captain1234","sender_type":"user","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"duplicate history","create_time":"10"}'
    sleep 0.1
    ;;
  'im +chat-messages-list')
    [ "$(cat "$FM_FAKE_COUNT" 2>/dev/null || printf 1)" -lt 2 ] || sleep 1.1
    printf '%s\n' '{"ok":true,"data":{"messages":[{"message_id":"om_history1234","sender":{"id":"ou_captain1234","type":"user"},"chat_id":"oc_chat1234","chat_type":"p2p","msg_type":"text","content":"history","create_time":"10","deleted":false}]}}'
    ;;
  'im +messages-send'|'im +messages-reply')
    if [ "${FM_FAKE_AMBIGUOUS_ONCE:-0}" = 1 ] && [ ! -f "${FM_FAKE_AMBIGUOUS_MARK:?}" ]; then
      : > "$FM_FAKE_AMBIGUOUS_MARK"
      printf 'not-json\n'
      exit 0
    fi
    printf '%s\n' '{"ok":true,"data":{"message_id":"om_sent1234","chat_id":"oc_chat1234"}}'
    ;;
  *)
    printf '%s\n' '{"ok":false,"error":{"type":"validation","subtype":"unexpected_fake_argv"}}' >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKE_LARK"

FM_HOME="$TRANSPORT_HOME" SESSION_FILE="$TRANSPORT_FILE" SESSION_DIR="$TRANSPORT_SESSION" SID="$SID" TOUCH_SENTINEL="$TOUCH_SENTINEL" node --input-type=module <<'JS'
import { bindSession, createPairing, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const home = process.env.FM_HOME;
createPairing(home, { botOpenId: "ou_bot1234", allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const binding = bindSession(home, { sessionId: process.env.SID, sessionFile: process.env.SESSION_FILE, sessionCwd: process.env.SESSION_DIR, headerId: process.env.SID, headerCwd: process.env.SESSION_DIR });
const result = registerAssistantOutbound(home, {
  text: `literal $(touch ${process.env.TOUCH_SENTINEL}) https://example.test/kept`,
  source: "tui",
  sourceRef: "in_transport0000000000000",
  sessionId: binding.session_id,
  bindingGeneration: binding.generation,
});
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS

BOOTSTRAP_OUT=$(FM_HOME="$TRANSPORT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh)
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Eq '^FEISHU: paired=yes binding=active generation=1 transport=' \
  || fail "paired session-start health did not report body-free Feishu status"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'ou_captain1234' \
  && fail "session-start Feishu health leaked the allowlisted open_id"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'oc_chat1234' \
  && fail "session-start Feishu health leaked the bound chat_id"
INERT_HOME="$TMP_ROOT/inert-home"
mkdir -p "$INERT_HOME/data" "$INERT_HOME/state" "$INERT_HOME/config" "$INERT_HOME/projects"
INERT_OUT=$(FM_HOME="$INERT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh)
printf '%s\n' "$INERT_OUT" | grep -q '^FEISHU:' \
  && fail "unpaired bootstrap reported an active Feishu feature"
[ ! -e "$INERT_HOME/state/feishu" ] && [ ! -e "$INERT_HOME/data/feishu" ] \
  || fail "unpaired bootstrap created Feishu private state"

: > "$FAKE_LOG"
if FM_HOME="$TRANSPORT_HOME" \
  FM_FEISHU_LARK_CLI="$FAKE_LARK" \
  FM_FAKE_LOG="$FAKE_LOG" \
  FM_FAKE_PROFILE=wrong \
  node bin/fm-feishu-transport.mjs run --once >"$TMP_ROOT/mismatch.out" 2>"$TMP_ROOT/mismatch.err"; then
  mismatch_status=0
else
  mismatch_status=$?
fi
[ "$mismatch_status" -ne 0 ] || fail "transport accepted a bot app/profile mismatch"
grep -Fq $'ARGV\tevent\tconsume' "$FAKE_LOG" \
  && fail "transport opened an event consumer before exact bot identity verification"

: > "$FAKE_LOG"
FM_HOME="$TRANSPORT_HOME" \
FM_FEISHU_LARK_CLI="$FAKE_LARK" \
FM_FAKE_LOG="$FAKE_LOG" \
FM_FAKE_COUNT="$FAKE_COUNT" \
FM_FAKE_DROP_ONCE=1 \
FM_FEISHU_MAX_BUFFERED_EVENTS=1 \
FM_FAKE_AMBIGUOUS_ONCE=1 \
FM_FAKE_AMBIGUOUS_MARK="$TMP_ROOT/ambiguous-once" \
FM_FEISHU_OUTBOX_POLL_MS=20 \
bash bin/fm-feishu-transport.sh run --max-cycles 2

[ ! -e "$TOUCH_SENTINEL" ] || fail "transport interpolated Assistant text into a shell"
[ "$(find "$TRANSPORT_HOME/state/feishu/inbox" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "history overlap, reconnect, and message_id dedupe did not converge to three unique events"
[ -n "$(find "$TRANSPORT_HOME/state/feishu/transport/diagnostics" -type f -name '*.json' -print -quit)" ] \
  || fail "drop/backpressure diagnostic was not preserved"
SEND_KEYS=$(awk -F '\t' '$2=="im" && ($3=="+messages-send" || $3=="+messages-reply") { for(i=1;i<=NF;i++) if($i=="--idempotency-key") print $(i+1) }' "$FAKE_LOG")
[ "$(printf '%s\n' "$SEND_KEYS" | grep -c .)" -eq 2 ] || fail "ambiguous success did not retry once"
[ "$(printf '%s\n' "$SEND_KEYS" | sort -u | grep -c .)" -eq 1 ] || fail "ambiguous success retry changed the stable idempotency key"
# shellcheck disable=SC2016 # This is intentionally literal shell-looking message text.
grep -Fq 'literal $(touch ' "$FAKE_LOG" || fail "transport did not preserve literal Assistant text in argv"
[ "$(FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).outbound_pending)))')" -eq 0 ] \
  || fail "successful retry did not publish a durable outbound receipt"

pass "no-Agent transport preserves ready/drop/history semantics, direct argv text, idempotent retry, and receipts"
