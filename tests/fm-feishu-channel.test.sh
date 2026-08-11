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
APP_FINGERPRINT=sha256:134510bfcd5236dbf6f222594a857cb6bb19bc6bf707c74b3eef174a47409445
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
APP_FINGERPRINT="$APP_FINGERPRINT" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { linkSync, mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  bindSession,
  claimNextOutbound,
  claimTransportOwner,
  createPairing,
  deterministicChunks,
  findInboundByDeliveryRef,
  ingressCounts,
  offerFeishuIngress,
  pathsForHome,
  publishFeishuInbound,
  receiptOutbound,
  registerPendingDecision,
  statusSummary,
  writeTransportHealth,
} from "./bin/fm-feishu-state.mjs";
import {
  encodeFeishuIngress,
  parseFeishuMarker,
  registerFeishuNativeChannel,
  renderFeishuSourceBadge,
} from "./.pi/extensions/lib/fm-feishu-native-channel.ts";

const home = process.env.FM_HOME;
const sessionId = process.env.SID;
const sessionFile = process.env.SESSION_FILE;
const sessionCwd = process.env.SESSION_DIR;
const pairing = createPairing(home, {
  appIdFingerprint: process.env.APP_FINGERPRINT,
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
const procStat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
const processStartToken = procStat.slice(procStat.lastIndexOf(")") + 2).trim().split(/\s+/)[19];
const transportNonce = "a".repeat(48);
assert.equal(claimTransportOwner(home, { nonce: transportNonce, moduleFile: join(process.cwd(), "bin/fm-feishu-transport.mjs"), processStartToken }).ok, true);
function markHealthy(activeBinding) {
  writeTransportHealth(home, {
    phase: "healthy",
    healthy: true,
    ownerPid: process.pid,
    ownerNonce: transportNonce,
    ownerProcessStartToken: processStartToken,
    bindingId: activeBinding.binding_id,
    bindingGeneration: activeBinding.generation,
  });
}
markHealthy(binding);

function context(id = sessionId, file = sessionFile, cwd = sessionCwd, persisted = []) {
  const notifications = [];
  const statuses = new Map();
  return {
    entries: persisted,
    notifications,
    statuses,
    ctx: {
      mode: "tui",
      hasUI: true,
      cwd,
      isProjectTrusted: () => true,
      isIdle: () => true,
      sessionManager: {
        getSessionFile: () => file,
        getSessionId: () => id,
        getHeader: () => ({ id, cwd }),
        getEntries: () => persisted,
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
  const customEntries = [];
  const commands = new Map();
  return {
    handlers,
    sends,
    customEntries,
    commands,
    on(event, handler) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
    registerCommand(name, options) { commands.set(name, options); },
    registerMarkdownTransformer(transformer) { this.transformer = transformer; },
    sendUserMessage(content, options) { sends.push({ content, options }); },
    appendEntry(customType, data) { customEntries.push({ customType, data }); },
  };
}

async function emit(pi, name, event, ctx) {
  const results = [];
  for (const handler of pi.handlers.get(name) ?? []) results.push(await handler({ type: name, ...event }, ctx));
  return results;
}

function remote(overrides = {}) {
  return {
    type: "im.message.receive_v1",
    event_id: "evt_remote_a",
    message_id: "om_remoteA1234",
    sender_id: "ou_captain1234",
    sender_type: "user",
    chat_id: "oc_chat1234",
    chat_type: "p2p",
    message_type: "text",
    content: "remote request",
    create_time: "1",
    ...overrides,
  };
}

const first = publishFeishuInbound(home, remote());
assert.equal(first.status, "published");
assert.equal(publishFeishuInbound(home, remote({ event_id: "evt_remote_dup" })).status, "duplicate");
assert.equal(publishFeishuInbound(home, remote({ message_id: "om_sameEvent1234" })).status, "duplicate");
assert.equal(publishFeishuInbound(home, remote({ event_id: "evt_bad_user", message_id: "om_badUser1234", sender_id: "ou_other1234" })).reason, "unauthorized-user");
assert.equal(publishFeishuInbound(home, remote({ event_id: "evt_bad_chat", message_id: "om_badChat1234", chat_id: "oc_other1234", chat_type: "group" })).reason, "unauthorized-chat");
assert.equal(publishFeishuInbound(home, remote({ event_id: "evt_bot", message_id: "om_bot1234", sender_type: "bot" })).reason, "bot-or-self");
assert.throws(() => publishFeishuInbound(home, remote({ event_id: "evt_stale_fence", message_id: "om_staleFence1234" }), {
  bindingFence: { bindingId: "bind_000000000000000000000000", bindingGeneration: 999, sessionId, chatId: "oc_chat1234" },
}), /binding generation changed/);
assert.equal(ingressCounts(home).pending, 1);

const session = context();
const pi = fakePi();
registerFeishuNativeChannel(pi);
assert(!pi.handlers.has("input"), "Feishu extension intercepted native TUI input");
assert(!pi.handlers.has("message_end") && !pi.handlers.has("turn_start"), "removed TUI transformation or acknowledgement hooks remained registered");
assert(!pi.handlers.has("tool_call"), "Feishu extension retained a special tool-effect policy");
await emit(pi, "session_start", { reason: "startup" }, session.ctx);
await new Promise((resolve) => setTimeout(resolve, 320));
assert.equal(pi.sends.length, 1, "accepted Feishu input was not submitted to Pi's native queue");
assert.equal(pi.sends[0].options?.deliverAs, "followUp", "Feishu input did not use Pi's native follow-up queue");
const marker = parseFeishuMarker(pi.sends[0].content);
assert.equal(marker?.deliveryRef, first.deliveryRef);
assert(!pi.sends[0].content.includes("ou_captain1234") && !pi.sends[0].content.includes("oc_chat1234"), "private Feishu identity leaked into Pi context");
assert(renderFeishuSourceBadge(pi.sends[0].content, "user").includes("Feishu - authorized P2P"));
assert.equal(ingressCounts(home).queued, 1, "native Pi submission was not recorded without a custom scheduler ACK");

const stateBeforeNative = JSON.stringify(ingressCounts(home));
pi.sendUserMessage("\u2063FIRSTMATE_OP: v1 watcher: native follow-up", { deliverAs: "followUp" });
assert.equal(JSON.stringify(ingressCounts(home)), stateBeforeNative, "ordinary Firstmate input entered Feishu durable ingress state");
assert.equal(pi.sends.at(-1).content, "\u2063FIRSTMATE_OP: v1 watcher: native follow-up");

session.entries.push({ type: "message", id: "user-feishu-1", message: { role: "user", content: pi.sends[0].content } });
await emit(pi, "message_start", { message: { role: "user", content: pi.sends[0].content } }, session.ctx);
const toolResults = await emit(pi, "tool_call", { toolName: "bash", toolCallId: "normal-tool", input: { command: "printf normal" } }, session.ctx);
assert(toolResults.every((result) => result?.block !== true), "Feishu request did not reach Pi's normal tool path");
registerPendingDecision(home, { decisionRef: "dec-native", decisionKey: "native-choice", sourceRef: first.deliveryRef, sessionId });
await emit(pi, "turn_end", { message: { role: "assistant", content: "Direct native-queue answer https://example.test/full" } }, session.ctx);
await emit(pi, "message_start", { message: { role: "user", content: "native TUI input remains unmarked" } }, session.ctx);
await emit(pi, "turn_end", { message: { role: "assistant", content: "Local TUI answer must not enter Feishu outbox" } }, session.ctx);
await emit(pi, "agent_settled", {}, session.ctx);
let claim = claimNextOutbound(home);
assert(claim, "settled Feishu response did not enter durable outbox");
assert.equal(claim.outbox.text, "Direct native-queue answer https://example.test/full");
assert.equal(claim.outbox.reply_to_message_id, "om_remoteA1234");
assert.equal(claim.outbox.decision_ref, "dec-native");
receiptOutbound(home, claim, { messageId: "om_outboundDecision1234", chatId: "oc_chat1234" });
assert.equal(statusSummary(home).outbound_pending, 0, "native TUI response was incorrectly sent to Feishu");

const unrelated = publishFeishuInbound(home, remote({ event_id: "evt_unrelated", message_id: "om_unrelated1234", reply_to: null, content: "unrelated" }));
assert(encodeFeishuIngress(findInboundByDeliveryRef(home, unrelated.deliveryRef)).includes("must not resolve any open decision"));
const exactReply = publishFeishuInbound(home, remote({ event_id: "evt_reply", message_id: "om_reply1234", reply_to: "om_outboundDecision1234", content: "exact reply" }));
const exactEvent = findInboundByDeliveryRef(home, exactReply.deliveryRef);
assert.equal(exactEvent.decision_ref, "dec-native");
assert.equal(exactEvent.decision_key, "native-choice");

await emit(pi, "session_shutdown", {}, session.ctx);
const resumedPi = fakePi();
registerFeishuNativeChannel(resumedPi);
const resumed = context(sessionId, sessionFile, sessionCwd, session.entries);
await emit(resumedPi, "session_start", { reason: "resume" }, resumed.ctx);
await new Promise((resolve) => setTimeout(resolve, 320));
assert(!resumedPi.sends.some((send) => parseFeishuMarker(send.content)?.deliveryRef === first.deliveryRef), "persisted Feishu input was resubmitted after exact session resume");
assert.equal(ingressCounts(home).delivered, 1, "session marker did not reconcile prior native-queue submission");
await emit(resumedPi, "session_shutdown", {}, resumed.ctx);

const wrongPi = fakePi();
registerFeishuNativeChannel(wrongPi);
const wrong = context("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", sessionFile, sessionCwd, []);
await emit(wrongPi, "session_start", { reason: "new" }, wrong.ctx);
await new Promise((resolve) => setTimeout(resolve, 100));
assert.equal(wrongPi.sends.length, 0, "wrong Pi session inherited the Feishu binding");
assert(String(wrong.statuses.get("fm-feishu")).includes("another Pi session"));

const chunks = deterministicChunks("alpha\n\nhttps://example.test/a/complete/url\n\nomega", 36);
assert.equal(chunks.join(""), "alpha\n\nhttps://example.test/a/complete/url\n\nomega");
assert(chunks.some((chunk) => chunk.includes("https://example.test/a/complete/url")));

const unsafeHome = join(home, "unsafe-home");
mkdirSync(join(unsafeHome, "data"), { recursive: true });
mkdirSync(join(unsafeHome, "state"), { recursive: true });
symlinkSync(join(home, "state", "feishu"), join(unsafeHome, "state", "feishu"));
assert.throws(() => createPairing(unsafeHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" }), /unsafe Feishu state directory/);

const hardlinkHome = join(home, "hardlink-home");
mkdirSync(join(hardlinkHome, "data"), { recursive: true });
mkdirSync(join(hardlinkHome, "state"), { recursive: true });
createPairing(hardlinkHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const hardlinkPairing = join(hardlinkHome, "data", "feishu", "pairing.json");
linkSync(hardlinkPairing, `${hardlinkPairing}.alias`);
assert.throws(() => statusSummary(hardlinkHome), /unsafe Feishu state file/);

const rebindHome = join(home, "rebind-home");
mkdirSync(join(rebindHome, "data"), { recursive: true });
mkdirSync(join(rebindHome, "state"), { recursive: true });
createPairing(rebindHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const rebindSession = join(rebindHome, "session");
mkdirSync(rebindSession);
const rebindFile = join(rebindSession, "s.jsonl");
writeFileSync(rebindFile, `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: rebindSession })}\n`);
const rebindBinding = bindSession(rebindHome, { sessionId, sessionFile: rebindFile, sessionCwd: rebindSession, headerId: sessionId, headerCwd: rebindSession });
const rebindInbound = publishFeishuInbound(rebindHome, remote({ event_id: "evt_rebind", message_id: "om_rebindSource1234" }));
offerFeishuIngress(rebindHome, rebindInbound.deliveryRef, { sessionId, bindingId: rebindBinding.binding_id, bindingGeneration: rebindBinding.generation });
assert.throws(() => bindSession(rebindHome, { sessionId, sessionFile: rebindFile, sessionCwd: rebindSession, headerId: sessionId, headerCwd: rebindSession }, { rebind: true }), /belongs to the current Pi native queue/);

const secretHome = join(home, "secret-home");
mkdirSync(join(secretHome, "data"), { recursive: true });
mkdirSync(join(secretHome, "state"), { recursive: true });
createPairing(secretHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const secretSession = join(secretHome, "session");
mkdirSync(secretSession);
const secretFile = join(secretSession, "s.jsonl");
writeFileSync(secretFile, `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: secretSession })}\n`);
const secretBinding = bindSession(secretHome, { sessionId, sessionFile: secretFile, sessionCwd: secretSession, headerId: sessionId, headerCwd: secretSession });
const secretInbound = publishFeishuInbound(secretHome, remote({ event_id: "evt_secret", message_id: "om_secretSource1234" }));
const paths = pathsForHome(secretHome);
const beforeIntents = readdirSync(paths.outboundRegistrationIntents).length;
const { persistAssistantOutboundIntent } = await import("./bin/fm-feishu-state.mjs");
const refused = persistAssistantOutboundIntent(secretHome, { text: "Authorization: Bearer fixed-secret-value-123456", source: "feishu", sourceRef: secretInbound.deliveryRef, sessionId, bindingGeneration: secretBinding.generation, replyTo: "om_secretSource1234" });
assert.equal(refused.status, "secret-refused");
assert.equal(readdirSync(paths.outboundRegistrationIntents).length, beforeIntents, "secret text was persisted before deterministic refusal");

console.log("ok - native Pi queue, exact Feishu provenance, durable state, and TUI-equivalent tool path");
JS

BOOTSTRAP_INERT_HOME="$TMP_ROOT/bootstrap-inert-home"
mkdir -p "$BOOTSTRAP_INERT_HOME/data" "$BOOTSTRAP_INERT_HOME/state"
DISABLED_BOOTSTRAP=$(FM_HOME="$BOOTSTRAP_INERT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh)
printf '%s\n' "$DISABLED_BOOTSTRAP" | grep -q '^FEISHU:' \
  && fail "unconfigured Feishu channel changed bootstrap behavior"
[ ! -e "$BOOTSTRAP_INERT_HOME/data/feishu" ] && [ ! -e "$BOOTSTRAP_INERT_HOME/state/feishu" ] \
  || fail "unconfigured Feishu channel created private state"

BRIDGE_FIXTURE="$TMP_ROOT/bridge-fixture"
mkdir -p "$BRIDGE_FIXTURE/.pi/extensions/lib" "$BRIDGE_FIXTURE/bin" "$BRIDGE_FIXTURE/node_modules/@earendil-works" "$BRIDGE_FIXTURE/home/state"
printf 'owned\n' > "$BRIDGE_FIXTURE/home/lock-mode"
cp "$ROOT/.pi/extensions/fm-primary-feishu-bridge.ts" "$BRIDGE_FIXTURE/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-feishu-native-channel.ts" "$BRIDGE_FIXTURE/.pi/extensions/lib/"
cp "$ROOT/bin/fm-feishu-state.d.mts" "$ROOT/bin/fm-feishu-state.mjs" "$BRIDGE_FIXTURE/bin/"
mkdir -p "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' > "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui/package.json"
cat > "$BRIDGE_FIXTURE/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { addChild() {} }
export class Text {}
JS
printf '%s\n' '{"type":"module"}' > "$BRIDGE_FIXTURE/package.json"
BRIDGE_SESSION="$BRIDGE_FIXTURE/session"
BRIDGE_SESSION_FILE="$BRIDGE_SESSION/current.jsonl"
BRIDGE_TRANSPORT_LOG="$BRIDGE_FIXTURE/transport.log"
mkdir -p "$BRIDGE_SESSION"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$BRIDGE_SESSION" > "$BRIDGE_SESSION_FILE"
cat > "$BRIDGE_FIXTURE/bin/fm-feishu-transport.sh" <<'SH'
#!/usr/bin/env bash
set -eu
node -e 'const fs=require("fs");const p=process.env.FM_HOME+"/data/feishu/bindings/active.json";const g=fs.existsSync(p)?JSON.parse(fs.readFileSync(p)).generation:"none";fs.appendFileSync(process.env.BRIDGE_TRANSPORT_LOG,process.argv[1]+" generation="+g+"\n")' "$1"
SH
chmod +x "$BRIDGE_FIXTURE/bin/fm-feishu-transport.sh"
FM_HOME="$BRIDGE_FIXTURE/home" \
FM_ROOT_OVERRIDE="$BRIDGE_FIXTURE" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
BRIDGE="$BRIDGE_FIXTURE/.pi/extensions/fm-primary-feishu-bridge.ts" \
BRIDGE_SESSION="$BRIDGE_SESSION" \
BRIDGE_SESSION_FILE="$BRIDGE_SESSION_FILE" \
BRIDGE_TRANSPORT_LOG="$BRIDGE_TRANSPORT_LOG" \
SID="$SID" \
APP_FINGERPRINT="$APP_FINGERPRINT" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const commands = new Map();
const handlers = new Map();
const pi = {
  on(name, handler) { handlers.set(name, handler); },
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
assert(!handlers.has("input") && !handlers.has("tool_call") && !handlers.has("turn_start"));
const notices = [];
const ctx = {
  mode: "tui",
  hasUI: true,
  cwd: process.env.BRIDGE_SESSION,
  isProjectTrusted() { return true; },
  sessionManager: {
    getSessionFile() { return process.env.BRIDGE_SESSION_FILE; },
    getSessionId() { return process.env.SID; },
    getHeader() { return { id: process.env.SID, cwd: process.env.BRIDGE_SESSION }; },
  },
  ui: { notify(message) { notices.push(String(message)); }, setStatus() {} },
  async reload() {},
};
await commands.get("fm-feishu-pair").handler(`ou_captain1234 oc_chat1234 ${process.env.APP_FINGERPRINT}`, ctx);
await commands.get("fm-feishu-bind").handler("", ctx);
await commands.get("fm-feishu-rebind").handler("", ctx);
await commands.get("fm-feishu-disable").handler("", ctx);
assert(existsSync(process.env.BRIDGE_TRANSPORT_LOG), notices.join("\n"));
assert.deepEqual(readFileSync(process.env.BRIDGE_TRANSPORT_LOG, "utf8").trim().split("\n"), ["stop generation=1", "stop generation=2"]);
assert(notices.every((message) => !message.includes("refused")), notices.join("\n"));
console.log("ok - local Pi bridge keeps native TUI/tool paths and stops transport before identity changes");
JS

# The transport test replaces the official SDK boundary with one local module.
# It exercises the SDK long-connection callbacks and message APIs without a
# real app, credential, network connection, webhook, Pi session, or message.
TRANSPORT_HOME="$TMP_ROOT/transport-home"
TRANSPORT_SESSION="$TMP_ROOT/transport-session"
TRANSPORT_FILE="$TRANSPORT_SESSION/current.jsonl"
MOCK_SDK="$TMP_ROOT/mock-feishu-sdk.mjs"
SDK_LOG="$TMP_ROOT/mock-sdk.log"
SDK_EVENTS="$TMP_ROOT/mock-sdk-events.json"
SDK_SEND_MARK="$TMP_ROOT/mock-sdk-send-mark"
SDK_SEND_COUNT="$TMP_ROOT/mock-sdk-send-count"
SDK_SEND_LOCK="$TMP_ROOT/mock-sdk-send-lock"
SDK_OVERLAP="$TMP_ROOT/mock-sdk-overlap"
TOUCH_SENTINEL="$TMP_ROOT/MUST_NOT_EXIST"
LARK_SENTINEL="$TMP_ROOT/LARK_CLI_MUST_NOT_RUN"
FAKE_BIN="$TMP_ROOT/fake-bin"
APP_ID=cli_0123456789abcdef
APP_SECRET=fixture-secret-never-logged
APP_FINGERPRINT=sha256:134510bfcd5236dbf6f222594a857cb6bb19bc6bf707c74b3eef174a47409445
mkdir -p "$TRANSPORT_HOME/data" "$TRANSPORT_HOME/state" "$TRANSPORT_SESSION" "$FAKE_BIN"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$TRANSPORT_SESSION" > "$TRANSPORT_FILE"
cat > "$FAKE_BIN/lark-cli" <<SH
#!/usr/bin/env bash
: > "$LARK_SENTINEL"
exit 91
SH
chmod +x "$FAKE_BIN/lark-cli"
cat > "$MOCK_SDK" <<'JS'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, appendFileSync } from "node:fs";

const logPath = process.env.FM_FAKE_SDK_LOG;
if (logPath) appendFileSync(logPath, `${JSON.stringify({ type: "module-import" })}\n`);
const log = (record) => {
  if (logPath) appendFileSync(logPath, `${JSON.stringify({ ...record, at: Date.now() })}\n`);
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const actions = () => {
  const path = process.env.FM_FAKE_SDK_EVENTS;
  return path && existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : [];
};

export const Domain = { Feishu: "https://open.feishu.cn" };
export const LoggerLevel = { error: "error" };

async function send(kind, payload) {
  const lock = process.env.FM_FAKE_SDK_SEND_LOCK;
  if (lock) {
    try { mkdirSync(lock); }
    catch { if (process.env.FM_FAKE_SDK_OVERLAP) writeFileSync(process.env.FM_FAKE_SDK_OVERLAP, "overlap\n"); }
  }
  const text = JSON.parse(payload.data.content).text;
  log({ type: "send", kind, uuid: payload.data.uuid, text, replyTo: payload.path?.message_id ?? null, receiveId: payload.data.receive_id ?? null });
  const mode = process.env.FM_FAKE_SDK_SEND_MODE || "success";
  const mark = process.env.FM_FAKE_SDK_SEND_MARK;
  if (mode === "ambiguous-once" && mark && !existsSync(mark)) {
    writeFileSync(mark, "ambiguous\n");
    if (lock) rmSync(lock, { recursive: true, force: true });
    const error = new Error("ambiguous fixture");
    error.request = {};
    throw error;
  }
  if (mode === "rate-limit-once" && mark && !existsSync(mark)) {
    writeFileSync(mark, String(Date.now()));
    if (lock) rmSync(lock, { recursive: true, force: true });
    const error = new Error("rate limit fixture");
    error.response = { status: 429, headers: { "retry-after": "1" }, data: { code: 99991400 } };
    throw error;
  }
  await sleep(Number(process.env.FM_FAKE_SDK_SEND_DELAY_MS || 0));
  let count = 0;
  const countPath = process.env.FM_FAKE_SDK_SEND_COUNT;
  if (countPath && existsSync(countPath)) count = Number(readFileSync(countPath, "utf8"));
  count += 1;
  if (countPath) writeFileSync(countPath, String(count));
  if (lock) rmSync(lock, { recursive: true, force: true });
  return { code: 0, data: { message_id: `om_sdkSent${count}1234`, chat_id: process.env.FM_FAKE_SDK_CHAT_ID || "oc_chat1234" } };
}

export class Client {
  constructor(options) {
    log({ type: "client", appId: options.appId, hasSecret: Boolean(options.appSecret), source: options.source });
    this.im = { v1: {
      chat: { get: async ({ path }) => {
        log({ type: "chat-get", chatId: path.chat_id });
        return { code: 0, data: { chat_id: path.chat_id, chat_mode: process.env.FM_FAKE_SDK_CHAT_MODE || "p2p" } };
      } },
      message: {
        create: async (payload) => send("create", payload),
        reply: async (payload) => send("reply", payload),
      },
    } };
  }
}

export class EventDispatcher {
  constructor() { this.handlers = {}; }
  register(handlers) { this.handlers = { ...this.handlers, ...handlers }; return this; }
}

export class WSClient {
  constructor(options) { this.options = options; log({ type: "ws-client", autoReconnect: options.autoReconnect, source: options.source }); }
  async start({ eventDispatcher }) {
    log({ type: "ws-start", event: "im.message.receive_v1" });
    this.options.onReady?.();
    for (const action of actions()) {
      if (action.kind === "reconnect") {
        this.options.onReconnecting?.();
        await sleep(20);
        this.options.onReconnected?.();
        await sleep(20);
        continue;
      }
      if (action.kind === "event") {
        try { await eventDispatcher.handlers["im.message.receive_v1"]?.(action.data); }
        catch { log({ type: "event-refused" }); }
      }
    }
  }
  close() { log({ type: "ws-close" }); }
}
JS

FM_HOME="$TRANSPORT_HOME" SESSION_FILE="$TRANSPORT_FILE" SESSION_DIR="$TRANSPORT_SESSION" SID="$SID" APP_FINGERPRINT="$APP_FINGERPRINT" TOUCH_SENTINEL="$TOUCH_SENTINEL" node --input-type=module <<'JS'
import { bindSession, createPairing, publishFeishuInbound, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const home = process.env.FM_HOME;
createPairing(home, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const binding = bindSession(home, { sessionId: process.env.SID, sessionFile: process.env.SESSION_FILE, sessionCwd: process.env.SESSION_DIR, headerId: process.env.SID, headerCwd: process.env.SESSION_DIR });
const source = publishFeishuInbound(home, { type: "im.message.receive_v1", event_id: "evt_sdk_a", message_id: "om_sdkA1234", sender_id: "ou_captain1234", sender_type: "user", chat_id: "oc_chat1234", chat_type: "p2p", message_type: "text", content: "sdk event A", create_time: "10" }, { transport: "feishu-sdk-long-connection" });
const result = registerAssistantOutbound(home, {
  text: `literal $(touch ${process.env.TOUCH_SENTINEL}) https://example.test/kept`,
  source: "feishu",
  sourceRef: source.deliveryRef,
  replyTo: "om_sdkA1234",
  sessionId: binding.session_id,
  bindingGeneration: binding.generation,
});
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS

BOOTSTRAP_OUT=$(FM_HOME="$TRANSPORT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_APP_ID="$APP_ID" FM_FEISHU_APP_SECRET="$APP_SECRET" bash bin/fm-bootstrap.sh)
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Eq '^FEISHU: paired=yes binding=active generation=1 transport=' \
  || fail "paired session-start health did not report body-free Feishu status"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'ou_captain1234' \
  && fail "session-start Feishu health leaked the allowlisted open_id"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'oc_chat1234' \
  && fail "session-start Feishu health leaked the bound chat_id"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq "$APP_SECRET" \
  && fail "session-start Feishu health leaked the SDK app secret"

INERT_HOME="$TMP_ROOT/sdk-inert-home"
INERT_SDK_LOG="$TMP_ROOT/inert-sdk.log"
mkdir -p "$INERT_HOME/data" "$INERT_HOME/state"
if FM_HOME="$INERT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FEISHU_APP_ID="$APP_ID" FM_FEISHU_APP_SECRET="$APP_SECRET" FM_FAKE_SDK_LOG="$INERT_SDK_LOG" \
  node bin/fm-feishu-transport.mjs run --once >"$TMP_ROOT/inert.out" 2>"$TMP_ROOT/inert.err"; then
  fail "unconfigured direct SDK transport started"
fi
[ ! -e "$INERT_SDK_LOG" ] || fail "unconfigured transport imported or initialized the SDK"

: > "$SDK_LOG"
if PATH="$FAKE_BIN:$PATH" FM_HOME="$TRANSPORT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FEISHU_APP_ID=cli_ffffffffffffffff FM_FEISHU_APP_SECRET="$APP_SECRET" FM_FAKE_SDK_LOG="$SDK_LOG" \
  node bin/fm-feishu-transport.mjs run --once >"$TMP_ROOT/app-mismatch.out" 2>"$TMP_ROOT/app-mismatch.err"; then
  fail "transport accepted an SDK app fingerprint mismatch"
fi
[ ! -s "$SDK_LOG" ] || fail "transport imported the SDK before validating the local app fingerprint"
[ ! -e "$LARK_SENTINEL" ] || fail "direct SDK transport executed lark-cli"

: > "$SDK_LOG"
if PATH="$FAKE_BIN:$PATH" FM_HOME="$TRANSPORT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FEISHU_APP_ID="$APP_ID" FM_FEISHU_APP_SECRET="$APP_SECRET" FM_FAKE_SDK_LOG="$SDK_LOG" FM_FAKE_SDK_CHAT_MODE=group \
  node bin/fm-feishu-transport.mjs run --once >"$TMP_ROOT/group-chat.out" 2>"$TMP_ROOT/group-chat.err"; then
  fail "transport accepted a configured group chat"
fi
node -e 'const fs=require("fs");const rows=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse);if(!rows.some(r=>r.type==="chat-get")||rows.some(r=>r.type==="ws-start"))process.exit(1)' "$SDK_LOG" \
  || fail "SDK long connection started before independent P2P verification"

cat > "$SDK_EVENTS" <<JSON
[
  {"kind":"event","data":{"event_id":"evt_sdk_a","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_captain1234"},"sender_type":"user"},"message":{"message_id":"om_sdkA1234","create_time":"10","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"{\\"text\\":\\"sdk event A\\"}"}}},
  {"kind":"event","data":{"event_id":"evt_sdk_a","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_captain1234"},"sender_type":"user"},"message":{"message_id":"om_sameEvent1234","create_time":"11","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"{\\"text\\":\\"duplicate event id\\"}"}}},
  {"kind":"event","data":{"event_id":"evt_sdk_other","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_captain1234"},"sender_type":"user"},"message":{"message_id":"om_sdkA1234","create_time":"12","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"{\\"text\\":\\"duplicate message id\\"}"}}},
  {"kind":"reconnect"},
  {"kind":"event","data":{"event_id":"evt_sdk_b","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_captain1234"},"sender_type":"user"},"message":{"message_id":"om_sdkB1234","create_time":"20","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"{\\"text\\":\\"sdk event B\\"}"}}},
  {"kind":"event","data":{"event_id":"evt_sdk_bad_user","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_other1234"},"sender_type":"user"},"message":{"message_id":"om_sdkBadUser1234","create_time":"21","chat_id":"oc_chat1234","chat_type":"p2p","message_type":"text","content":"{\\"text\\":\\"reject me\\"}"}}},
  {"kind":"event","data":{"event_id":"evt_sdk_bad_chat","app_id":"$APP_ID","sender":{"sender_id":{"open_id":"ou_captain1234"},"sender_type":"user"},"message":{"message_id":"om_sdkBadChat1234","create_time":"22","chat_id":"oc_other1234","chat_type":"group","message_type":"text","content":"{\\"text\\":\\"reject me too\\"}"}}}
]
JSON
rm -f "$SDK_SEND_MARK" "$SDK_SEND_COUNT" "$SDK_OVERLAP" "$LARK_SENTINEL"
: > "$SDK_LOG"
COMMON_SDK_ENV=(
  "FM_HOME=$TRANSPORT_HOME"
  "FM_FEISHU_SDK_MODULE=$MOCK_SDK"
  "FM_FEISHU_SDK_TEST_MODE=1"
  "FM_FEISHU_APP_ID=$APP_ID"
  "FM_FEISHU_APP_SECRET=$APP_SECRET"
  "FM_FAKE_SDK_LOG=$SDK_LOG"
  "FM_FAKE_SDK_EVENTS=$SDK_EVENTS"
  "FM_FAKE_SDK_SEND_MARK=$SDK_SEND_MARK"
  "FM_FAKE_SDK_SEND_COUNT=$SDK_SEND_COUNT"
  "FM_FAKE_SDK_CHAT_ID=oc_chat1234"
)
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=ambiguous-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
sleep 1.1
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=ambiguous-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once

[ ! -e "$LARK_SENTINEL" ] || fail "direct SDK transport retained a lark-cli runtime path"
[ ! -e "$TOUCH_SENTINEL" ] || fail "SDK transport evaluated Assistant text as shell input"
[ "$(find "$TRANSPORT_HOME/state/feishu/inbox" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "SDK replay and event/message dedupe did not converge to two accepted messages"
FM_HOME="$TRANSPORT_HOME" node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const dir = join(process.env.FM_HOME, "state", "feishu", "inbox");
const events = readdirSync(dir).filter((name) => name.endsWith(".json")).map((name) => JSON.parse(readFileSync(join(dir, name), "utf8"))).sort((a, b) => a.ingress_seq - b.ingress_seq);
assert.deepEqual(events.map((event) => event.message_id), ["om_sdkA1234", "om_sdkB1234"]);
assert(events.every((event) => event.transport === "feishu-sdk-long-connection"));
JS
node -e 'const fs=require("fs");const rows=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse);const sends=rows.filter(r=>r.type==="send");if(sends.length!==2||new Set(sends.map(r=>r.uuid)).size!==1||!rows.some(r=>r.type==="ws-start")||!rows.some(r=>r.type==="client"&&r.hasSecret===true)||rows.some(r=>JSON.stringify(r).includes(process.argv[2])))process.exit(1)' "$SDK_LOG" "$APP_SECRET" \
  || fail "SDK startup, stable outbound UUID, or credential-redaction evidence was wrong"
[ "$(FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).outbound_pending)))')" -eq 0 ] \
  || fail "SDK success did not publish a durable outbound receipt"
[ -n "$(find "$TRANSPORT_HOME/state/feishu/quarantine" -type f -name '*.json' -print -quit)" ] \
  || fail "SDK boundary did not durably refuse unauthorized identity/chat events"

FM_HOME="$TRANSPORT_HOME" SESSION_ID="$SID" node --input-type=module <<'JS'
import { publishFeishuInbound, readActiveBinding, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.FM_HOME);
const source = publishFeishuInbound(process.env.FM_HOME, { type: "im.message.receive_v1", event_id: "evt_rate_source", message_id: "om_rateSource1234", sender_id: "ou_captain1234", sender_type: "user", chat_id: "oc_chat1234", chat_type: "p2p", message_type: "text", content: "rate source", create_time: "30" });
const result = registerAssistantOutbound(process.env.FM_HOME, { text: "server delayed SDK retry", source: "feishu", sourceRef: source.deliveryRef, replyTo: "om_rateSource1234", sessionId: process.env.SESSION_ID, bindingGeneration: binding.generation });
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS
rm -f "$SDK_SEND_MARK"
: > "$SDK_LOG"
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=rate-limit-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
sleep 1.1
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=rate-limit-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
node -e 'const fs=require("fs");const sends=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse).filter(r=>r.type==="send");if(sends.length!==2||sends[1].at-sends[0].at<900||new Set(sends.map(r=>r.uuid)).size!==1)process.exit(1)' "$SDK_LOG" \
  || fail "SDK Retry-After mapping shortened the delay or changed UUID"

rm -f "$SDK_SEND_MARK" "$SDK_OVERLAP" "$SDK_SEND_LOCK"
: > "$SDK_LOG"
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_DELAY_MS=300 FM_FAKE_SDK_SEND_LOCK="$SDK_SEND_LOCK" FM_FAKE_SDK_OVERLAP="$SDK_OVERLAP" FM_FEISHU_OUTBOX_POLL_MS=20 \
  bash bin/fm-feishu-transport.sh start >"$TMP_ROOT/owner-start.out"
OWNER_PATH="$TRANSPORT_HOME/state/feishu/transport/owner.json"
healthy=0
for _ in $(seq 1 150); do
  phase=$(FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).transport_phase||"")}catch{}})' || true)
  if [ "$phase" = healthy ]; then healthy=1; break; fi
  sleep 0.03
done
[ "$healthy" -eq 1 ] || fail "direct SDK long connection did not become healthy"
FM_HOME="$TRANSPORT_HOME" SESSION_ID="$SID" node --input-type=module <<'JS'
import { publishFeishuInbound, readActiveBinding, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.FM_HOME);
const source = publishFeishuInbound(process.env.FM_HOME, { type: "im.message.receive_v1", event_id: "evt_single_source", message_id: "om_singleSource1234", sender_id: "ou_captain1234", sender_type: "user", chat_id: "oc_chat1234", chat_type: "p2p", message_type: "text", content: "single source", create_time: "40" });
const result = registerAssistantOutbound(process.env.FM_HOME, { text: "single flight SDK send", source: "feishu", sourceRef: source.deliveryRef, replyTo: "om_singleSource1234", sessionId: process.env.SESSION_ID, bindingGeneration: binding.generation });
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS
settled=0
for _ in $(seq 1 150); do
  pending=$(FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).outbound_pending)))')
  if [ "$pending" -eq 0 ]; then settled=1; break; fi
  sleep 0.03
done
if [ "$settled" -ne 1 ]; then
  printf '%s\n' '--- SDK LOG ---' >&2
  cat "$SDK_LOG" >&2
  printf '%s\n' '--- STATUS ---' >&2
  FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public >&2 || true
  fail "serialized SDK outbound send did not settle"
fi
[ ! -e "$SDK_OVERLAP" ] || fail "SDK outbound timer overlapped an active send"

OWNER_BACKUP="$TMP_ROOT/owner.json"
cp "$OWNER_PATH" "$OWNER_BACKUP"
OWNER_PID=$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1])).pid))' "$OWNER_PATH")
node -e 'const fs=require("fs");const p=process.argv[1];const o=JSON.parse(fs.readFileSync(p));o.nonce="a".repeat(48);fs.writeFileSync(p,JSON.stringify(o)+"\n",{mode:0o600})' "$OWNER_PATH"
FM_HOME="$TRANSPORT_HOME" bash bin/fm-feishu-transport.sh stop >"$TMP_ROOT/owner-refused.out"
kill -0 "$OWNER_PID" 2>/dev/null || fail "owner verification process exited before the refusal check"
grep -Fq 'no process was signalled' "$TMP_ROOT/owner-refused.out" || fail "transport stop did not refuse a nonce mismatch"
cp "$OWNER_BACKUP" "$OWNER_PATH"
FM_HOME="$TRANSPORT_HOME" bash bin/fm-feishu-transport.sh stop >"$TMP_ROOT/owner-stop.out"
grep -Fq 'feishu transport stopped' "$TMP_ROOT/owner-stop.out" || fail "verified SDK transport owner did not stop gracefully"

pass "official-SDK long-connection transport is inert, identity-fenced, deduplicated, and durably serialized outbound"
