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
LIFECYCLE_SCRIPT="$TMP_ROOT/lifecycle-noop.mjs"
SID=12345678-1234-1234-1234-123456789abc
APP_FINGERPRINT=sha256:134510bfcd5236dbf6f222594a857cb6bb19bc6bf707c74b3eef174a47409445
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
printf 'owned\n' > "$HOME_DIR/lock-mode"
cat > "$LOCK_SCRIPT" <<'SH'
#!/usr/bin/env bash
mode=$(cat "${FM_HOME:?}/lock-mode" 2>/dev/null || printf other)
printf '%s\n' "$mode"
[ "$mode" = owned ]
SH
chmod +x "$LOCK_SCRIPT"
printf '%s\n' 'process.stdin.resume();' > "$LIFECYCLE_SCRIPT"

FM_HOME="$HOME_DIR" \
FM_ROOT_OVERRIDE="$ROOT" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_LIFECYCLE_SCRIPT="$LIFECYCLE_SCRIPT" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
SESSION_FILE="$SESSION_FILE" \
SESSION_DIR="$SESSION_DIR" \
SID="$SID" \
APP_FINGERPRINT="$APP_FINGERPRINT" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, linkSync, mkdirSync, readFileSync, readdirSync, symlinkSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  bindSession,
  claimNextOutbound,
  claimTransportOwner,
  convergeConfiguredSession,
  createPairing,
  deterministicChunks,
  findInboundByDeliveryRef,
  ingressCounts,
  offerFeishuIngress,
  pathsForHome,
  pendingFeishuIngress,
  publishFeishuInbound,
  receiptOutbound,
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
const preBindingAssistant = {
  type: "message",
  id: "00000001",
  parentId: null,
  timestamp: "2026-08-12T00:00:00.000Z",
  message: { role: "assistant", content: [{ type: "text", text: "historical response before binding" }] },
};
const binding = bindSession(home, {
  sessionId,
  sessionFile,
  sessionCwd,
  headerId: sessionId,
  headerCwd: sessionCwd,
  outboundAfterEntryId: preBindingAssistant.id,
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
  const eventChannels = new Map();
  return {
    handlers,
    sends,
    customEntries,
    commands,
    events: {
      emit(channel, data) {
        for (const handler of eventChannels.get(channel) ?? []) handler(data);
      },
      on(channel, handler) {
        const listeners = eventChannels.get(channel) ?? new Set();
        listeners.add(handler);
        eventChannels.set(channel, listeners);
        return () => listeners.delete(handler);
      },
    },
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

async function holdLiveStateLock(path, milliseconds) {
  const ready = `${path}.ready`;
  const child = spawn(process.execPath, ["--input-type=module", "-e", `
    import { closeSync, fsyncSync, openSync, unlinkSync, writeFileSync } from "node:fs";
    const fd = openSync(process.env.LOCK_PATH, "wx", 0o600);
    writeFileSync(fd, String(process.pid) + "\\n", "utf8");
    fsyncSync(fd);
    closeSync(fd);
    writeFileSync(process.env.READY_PATH, "ready\\n");
    setTimeout(() => { unlinkSync(process.env.LOCK_PATH); }, Number(process.env.HOLD_MS));
  `], {
    env: { ...process.env, LOCK_PATH: path, READY_PATH: ready, HOLD_MS: String(milliseconds) },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exited = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => code === 0 ? resolve() : reject(new Error(`lock holder exited ${code}: ${stderr}`)));
  });
  for (let attempt = 0; attempt < 100 && !existsSync(ready); attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert(existsSync(ready), "concurrent lock holder did not acquire the fixture lock");
  return { exited };
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

const session = context(sessionId, sessionFile, sessionCwd, [preBindingAssistant]);
const pi = fakePi();
registerFeishuNativeChannel(pi);
const pairingLockHolder = await holdLiveStateLock(join(pathsForHome(home).stateRoot, ".pairing.lock"), 6000);
assert(!pi.handlers.has("input"), "Feishu extension intercepted native TUI input");
assert(!pi.handlers.has("message_end") && !pi.handlers.has("turn_start"), "removed TUI transformation or acknowledgement hooks remained registered");
assert(!pi.handlers.has("tool_call"), "Feishu extension retained a special tool-effect policy");
await emit(pi, "session_start", { reason: "startup" }, session.ctx);
await new Promise((resolve) => setImmediate(resolve));
await pairingLockHolder.exited;
for (let attempt = 0; attempt < 30 && pi.sends.length === 0; attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100));
}
assert.equal(pi.sends.length, 1, `accepted Feishu input did not recover after live state-lock contention: ${JSON.stringify([...session.statuses])} ${JSON.stringify(session.notifications)}`);
assert.equal(session.notifications.filter(({ message }) => message.includes("transient state-lock contention")).length, 1, "live lock contention did not produce one bounded-retry notice");
assert(!session.notifications.some(({ message }) => message.includes("ingress stopped safely")), "live lock contention stopped the converged ingress runtime");
await new Promise((resolve) => setTimeout(resolve, 800));
assert.equal(pi.sends.length, 1, "repeated pump ticks duplicated the recovered native-queue offer");
assert.equal(pi.sends[0].options?.deliverAs, "steer", "Feishu input did not use Pi's native steering queue");
const marker = parseFeishuMarker(pi.sends[0].content);
assert.equal(marker?.deliveryRef, first.deliveryRef);
assert(!pi.sends[0].content.includes("ou_captain1234") && !pi.sends[0].content.includes("oc_chat1234"), "private Feishu identity leaked into Pi context");
assert(renderFeishuSourceBadge(pi.sends[0].content, "user").includes("Feishu - authorized P2P"));
assert.equal(ingressCounts(home).queued, 1, "native Pi submission was not recorded without a custom scheduler ACK");

const stateBeforeNative = JSON.stringify(ingressCounts(home));
pi.sendUserMessage("\u2063FIRSTMATE_OP: v1 watcher: native follow-up", { deliverAs: "followUp" });
assert.equal(JSON.stringify(ingressCounts(home)), stateBeforeNative, "ordinary Firstmate input entered Feishu durable ingress state");
assert.equal(pi.sends.at(-1).content, "\u2063FIRSTMATE_OP: v1 watcher: native follow-up");
assert.equal(pi.sends.at(-1).options?.deliverAs, "followUp", "ordinary Firstmate operational input lost its existing follow-up mode");

session.entries.push({ type: "message", id: "00000002", parentId: "00000001", timestamp: "2026-08-12T00:00:01.000Z", message: { role: "user", content: pi.sends[0].content } });
await emit(pi, "message_start", { message: session.entries.at(-1).message }, session.ctx);
const toolResults = await emit(pi, "tool_call", { toolName: "bash", toolCallId: "normal-tool", input: { command: "printf normal" } }, session.ctx);
assert(toolResults.every((result) => result?.block !== true), "Feishu request did not reach Pi's normal tool path");

async function finalizeAssistant(id, content, timestamp) {
  const message = { role: "assistant", content };
  session.entries.push({ type: "message", id, parentId: session.entries.at(-1)?.id ?? null, timestamp, message });
  await emit(pi, "turn_end", { message, toolResults: [] }, session.ctx);
}

await finalizeAssistant("00000003", [{ type: "text", text: "Direct Feishu answer https://example.test/full" }], "2026-08-12T00:00:02.000Z");
session.entries.push({ type: "message", id: "00000004", parentId: "00000003", timestamp: "2026-08-12T00:00:03.000Z", message: { role: "user", content: "native TUI input remains unmarked" } });
await emit(pi, "message_start", { message: session.entries.at(-1).message }, session.ctx);
await finalizeAssistant("00000005", [{ type: "text", text: "Local TUI answer is mirrored too" }], "2026-08-12T00:00:04.000Z");
session.entries.push({ type: "message", id: "00000006", parentId: "00000005", timestamp: "2026-08-12T00:00:05.000Z", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 routine" } });
await finalizeAssistant("00000007", [{ type: "text", text: "Captain, shipshape." }], "2026-08-12T00:00:06.000Z");
await finalizeAssistant("00000008", [{ type: "thinking", thinking: "private" }, { type: "toolCall", id: "call-1", name: "read", arguments: {} }], "2026-08-12T00:00:07.000Z");
session.entries.push({ type: "custom", id: "00000009", parentId: "00000008", timestamp: "2026-08-12T00:00:08.000Z", customType: "tui-only", data: { message: "local alert" } });
await finalizeAssistant("0000000a", [{ type: "text", text: "Watcher answer is mirrored too" }], "2026-08-12T00:00:09.000Z");
await finalizeAssistant("0000000b", [{ type: "text", text: "   " }], "2026-08-12T00:00:10.000Z");

const mirrored = [];
for (let claim = claimNextOutbound(home); claim; claim = claimNextOutbound(home)) {
  mirrored.push({ id: claim.outbox.assistant_entry_id, text: claim.outbox.text });
  assert.equal(claim.outbox.source, "pi-assistant");
  assert(!Object.hasOwn(claim.outbox, "reply_to_message_id"), "general Assistant mirror retained originating-message reply coupling");
  receiptOutbound(home, claim, { messageId: `om_outbound${claim.outbox.assistant_entry_id}`, chatId: "oc_chat1234" });
}
assert.deepEqual(mirrored, [
  { id: "00000003", text: "Direct Feishu answer https://example.test/full" },
  { id: "00000005", text: "Local TUI answer is mirrored too" },
  { id: "0000000a", text: "Watcher answer is mirrored too" },
]);
assert.equal(statusSummary(home).outbound_pending, 0);

const pairingPath = pathsForHome(home).pairing;
const validPairingBytes = readFileSync(pairingPath, "utf8");
writeFileSync(pairingPath, "{malformed\n");
for (let attempt = 0; attempt < 20 && !session.notifications.some(({ message }) => message.includes("malformed Feishu JSON")); attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
assert(session.notifications.some(({ message }) => message.includes("Feishu ingress stopped safely") && message.includes("malformed Feishu JSON")), "non-retryable state corruption did not stop ingress distinctly");
writeFileSync(pairingPath, validPairingBytes);
const stoppedSendCount = pi.sends.length;
await new Promise((resolve) => setTimeout(resolve, 500));
assert.equal(pi.sends.length, stoppedSendCount, "a stopped non-retryable runtime restarted without a lifecycle boundary");

await emit(pi, "session_shutdown", {}, session.ctx);
const resumedPi = fakePi();
registerFeishuNativeChannel(resumedPi);
const resumed = context(sessionId, sessionFile, sessionCwd, session.entries);
await emit(resumedPi, "session_start", { reason: "resume" }, resumed.ctx);
await new Promise((resolve) => setTimeout(resolve, 320));
assert(!resumedPi.sends.some((send) => parseFeishuMarker(send.content)?.deliveryRef === first.deliveryRef), "persisted Feishu input was resubmitted after exact session resume");
assert.equal(ingressCounts(home).delivered, 1, "session marker did not reconcile prior native-queue submission");
assert.equal(claimNextOutbound(home), undefined, "persisted Assistant entries were mirrored again after exact session resume");
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
const markdownText = [
  "Intro **bold** and `inline code`.",
  "",
  "[link](https://example.test/markdown)",
  "",
  "```js",
  'const marker = "<&>";',
  "```",
  "",
  "Tail with a snowman ☃.",
].join("\n");
const markdownChunks = deterministicChunks(markdownText, 60);
assert(markdownChunks.length > 1, "Markdown chunk fixture did not cross a deterministic boundary");
assert.equal(markdownChunks.join(""), markdownText, "Markdown-aware chunking changed finalized Assistant text");
assert(markdownChunks.some((chunk) => chunk.includes("`inline code`")), "Markdown chunking split an inline code span");
assert(markdownChunks.some((chunk) => chunk.includes("[link](https://example.test/markdown)")), "Markdown chunking split a link");
assert(markdownChunks.some((chunk) => chunk.includes('```js\nconst marker = "<&>";\n```')), "Markdown chunking split a fenced code block");
assert.throws(() => deterministicChunks(`\`${"x".repeat(80)}\``, 60), /complete Markdown construct/, "oversize Markdown syntax was split into malformed cards");

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
assert.throws(() => offerFeishuIngress(rebindHome, rebindInbound.deliveryRef, { sessionId, bindingId: rebindBinding.binding_id, bindingGeneration: rebindBinding.generation + 1 }), /binding fence mismatch/, "changed generation reached the native Pi queue");
offerFeishuIngress(rebindHome, rebindInbound.deliveryRef, { sessionId, bindingId: rebindBinding.binding_id, bindingGeneration: rebindBinding.generation });
assert.throws(() => bindSession(rebindHome, { sessionId, sessionFile: rebindFile, sessionCwd: rebindSession, headerId: sessionId, headerCwd: rebindSession }, { rebind: true }), /belongs to the current Pi native queue/);
const replacementId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const replacementFile = join(rebindSession, "replacement.jsonl");
writeFileSync(replacementFile, `${JSON.stringify({ type: "session", version: 3, id: replacementId, cwd: rebindSession })}\n`);
assert.throws(() => convergeConfiguredSession(rebindHome, {
  appIdFingerprint: process.env.APP_FINGERPRINT,
  allowedUser: "ou_captain1234",
  allowedChat: "oc_chat1234",
}, {
  sessionId: replacementId,
  sessionFile: replacementFile,
  sessionCwd: rebindSession,
  headerId: replacementId,
  headerCwd: rebindSession,
}), /belongs to the prior Pi native queue/);

const secretHome = join(home, "secret-home");
mkdirSync(join(secretHome, "data"), { recursive: true });
mkdirSync(join(secretHome, "state"), { recursive: true });
createPairing(secretHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const secretSession = join(secretHome, "session");
mkdirSync(secretSession);
const secretFile = join(secretSession, "s.jsonl");
writeFileSync(secretFile, `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: secretSession })}\n`);
const secretBinding = bindSession(secretHome, { sessionId, sessionFile: secretFile, sessionCwd: secretSession, headerId: sessionId, headerCwd: secretSession });
const paths = pathsForHome(secretHome);
const beforeIntents = readdirSync(paths.outboundRegistrationIntents).length;
const { persistAssistantOutboundIntent } = await import("./bin/fm-feishu-state.mjs");
const refused = persistAssistantOutboundIntent(secretHome, { text: "Authorization: Bearer fixed-secret-value-123456", assistantEntryId: "abcdef01", sessionOrder: 1, sessionEntryTimestamp: "2026-08-12T00:00:00.000Z", sessionId, bindingGeneration: secretBinding.generation });
assert.equal(refused.status, "secret-refused");
assert.equal(readdirSync(paths.outboundRegistrationIntents).length, beforeIntents, "secret text was persisted before deterministic refusal");

const lockHome = join(home, "lock-home");
mkdirSync(join(lockHome, "data"), { recursive: true });
mkdirSync(join(lockHome, "state"), { recursive: true });
createPairing(lockHome, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const lockSession = join(lockHome, "session");
mkdirSync(lockSession);
const lockSessionFile = join(lockSession, "s.jsonl");
writeFileSync(lockSessionFile, `${JSON.stringify({ type: "session", version: 3, id: sessionId, cwd: lockSession })}\n`);
const lockBinding = bindSession(lockHome, { sessionId, sessionFile: lockSessionFile, sessionCwd: lockSession, headerId: sessionId, headerCwd: lockSession });
const lockFence = { sessionId, bindingId: lockBinding.binding_id, bindingGeneration: lockBinding.generation };
const lockPaths = pathsForHome(lockHome);
const pairingLock = join(lockPaths.stateRoot, ".pairing.lock");
writeFileSync(pairingLock, "2147483647\n", { mode: 0o600 });
const old = new Date(Date.now() - 31000);
utimesSync(pairingLock, old, old);
assert.deepEqual(pendingFeishuIngress(lockHome, lockFence), [], "stale dead-owner lock was not reclaimed");
writeFileSync(pairingLock, "2147483647\n", { mode: 0o600 });
assert.throws(() => pendingFeishuIngress(lockHome, lockFence), /owner is not live within the stale-owner grace period/);
unlinkSync(pairingLock);
writeFileSync(pairingLock, "not-a-pid\n", { mode: 0o600 });
utimesSync(pairingLock, old, old);
assert.throws(() => pendingFeishuIngress(lockHome, lockFence), /malformed Feishu pairing state lock/);
unlinkSync(pairingLock);
symlinkSync(lockPaths.pairing, pairingLock);
assert.throws(() => pendingFeishuIngress(lockHome, lockFence), /unsafe Feishu pairing state lock/);
unlinkSync(pairingLock);

console.log("ok - native Pi steering, lock-contention recovery, state safety, and all-origin Assistant mirroring");
JS

BOOTSTRAP_INERT_HOME="$TMP_ROOT/bootstrap-inert-home"
mkdir -p "$BOOTSTRAP_INERT_HOME/data" "$BOOTSTRAP_INERT_HOME/state"
DISABLED_BOOTSTRAP=$(FM_HOME="$BOOTSTRAP_INERT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh)
printf '%s\n' "$DISABLED_BOOTSTRAP" | grep -q '^FEISHU:' \
  && fail "unconfigured Feishu channel changed bootstrap behavior"
[ ! -e "$BOOTSTRAP_INERT_HOME/data/feishu" ] && [ ! -e "$BOOTSTRAP_INERT_HOME/state/feishu" ] \
  || fail "unconfigured Feishu channel created private state"

BRIDGE_FIXTURE="$TMP_ROOT/bridge-fixture"
mkdir -p "$BRIDGE_FIXTURE/.pi/extensions/lib" "$BRIDGE_FIXTURE/bin" "$BRIDGE_FIXTURE/node_modules/@earendil-works" "$BRIDGE_FIXTURE/home/config" "$BRIDGE_FIXTURE/home/state"
printf 'FM_FEISHU_ENABLED=true\n' > "$BRIDGE_FIXTURE/home/config/feishu.env"
chmod 600 "$BRIDGE_FIXTURE/home/config/feishu.env"
printf 'other\n' > "$BRIDGE_FIXTURE/home/lock-mode"
cp "$ROOT/.pi/extensions/fm-primary-feishu-bridge.ts" "$BRIDGE_FIXTURE/.pi/extensions/"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$BRIDGE_FIXTURE/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-feishu-native-channel.ts" "$BRIDGE_FIXTURE/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$BRIDGE_FIXTURE/.pi/extensions/lib/"
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
BRIDGE_LIFECYCLE_LOG="$BRIDGE_FIXTURE/lifecycle.log"
mkdir -p "$BRIDGE_SESSION"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$BRIDGE_SESSION" > "$BRIDGE_SESSION_FILE"
cat > "$BRIDGE_FIXTURE/bin/fm-feishu-lifecycle.mjs" <<'JS'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { convergeConfiguredSession } from "./fm-feishu-state.mjs";
let body = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { body += chunk; });
process.stdin.on("end", () => {
  if (readFileSync(`${process.env.FM_HOME}/config/feishu.env`, "utf8").includes("FM_FEISHU_ENABLED=false")) return;
  const identity = JSON.parse(body);
  const { binding } = convergeConfiguredSession(process.env.FM_HOME, {
    appIdFingerprint: process.env.APP_FINGERPRINT,
    allowedUser: "ou_captain1234",
    allowedChat: "oc_chat1234",
  }, identity);
  appendFileSync(process.env.BRIDGE_LIFECYCLE_LOG, `${identity.sessionId}\n`);
  const transportDir = `${process.env.FM_HOME}/state/feishu/transport`;
  const owner = `${transportDir}/fixture-owner`;
  if (!existsSync(owner)) {
    mkdirSync(transportDir, { recursive: true });
    writeFileSync(owner, `${binding.binding_id}\n`);
    appendFileSync(process.env.BRIDGE_TRANSPORT_LOG, `start generation=${binding.generation}\n`);
  } else if (readFileSync(owner, "utf8").trim() !== binding.binding_id) {
    throw new Error("fixture transport owner did not follow the exact binding");
  }
});
JS
cat > "$BRIDGE_FIXTURE/bin/fm-feishu-transport.sh" <<'SH'
#!/usr/bin/env bash
set -eu
node -e 'const fs=require("fs");const p=process.env.FM_HOME+"/data/feishu/bindings/active.json";const g=fs.existsSync(p)?JSON.parse(fs.readFileSync(p)).generation:"none";fs.appendFileSync(process.env.BRIDGE_TRANSPORT_LOG,process.argv[1]+" generation="+g+"\n")' "$1"
SH
chmod +x "$BRIDGE_FIXTURE/bin/fm-feishu-transport.sh"
cat > "$BRIDGE_FIXTURE/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'owned\n' > "${FM_HOME:?}/lock-mode"
SH
chmod +x "$BRIDGE_FIXTURE/bin/fm-sessionstart-run.sh"
FM_HOME="$BRIDGE_FIXTURE/home" \
FM_ROOT_OVERRIDE="$BRIDGE_FIXTURE" \
FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
FM_FEISHU_LIFECYCLE_SCRIPT="$BRIDGE_FIXTURE/bin/fm-feishu-lifecycle.mjs" \
FM_FEISHU_DISABLE_AUTOSTART=1 \
BRIDGE="$BRIDGE_FIXTURE/.pi/extensions/fm-primary-feishu-bridge.ts" \
TURNEND="$BRIDGE_FIXTURE/.pi/extensions/fm-primary-turnend-guard.ts" \
BRIDGE_SESSION="$BRIDGE_SESSION" \
BRIDGE_SESSION_FILE="$BRIDGE_SESSION_FILE" \
BRIDGE_LIFECYCLE_LOG="$BRIDGE_LIFECYCLE_LOG" \
BRIDGE_TRANSPORT_LOG="$BRIDGE_TRANSPORT_LOG" \
SID="$SID" \
APP_FINGERPRINT="$APP_FINGERPRINT" \
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
function fakeEventBus() {
  const channels = new Map();
  return {
    emit(channel, data) {
      for (const handler of channels.get(channel) ?? []) handler(data);
    },
    on(channel, handler) {
      const handlers = channels.get(channel) ?? new Set();
      handlers.add(handler);
      channels.set(channel, handlers);
      return () => handlers.delete(handler);
    },
  };
}
const events = fakeEventBus();
function fakePi() {
  const commands = new Map();
  const handlers = new Map();
  return {
    commands,
    handlers,
    events,
    on(name, handler) {
      const list = handlers.get(name) ?? [];
      list.push(handler);
      handlers.set(name, list);
    },
    registerMarkdownTransformer() {},
    registerEntryRenderer() {},
    registerCommand(name, options) { commands.set(name, options); },
    appendEntry() {},
    sendUserMessage() {},
    sendMessage() {},
  };
}
async function emit(pi, name, event, ctx) {
  for (const handler of pi.handlers.get(name) ?? []) await handler({ type: name, ...event }, ctx);
}
const bridge = await import(pathToFileURL(process.env.BRIDGE).href);
const turnend = await import(pathToFileURL(process.env.TURNEND).href);
let pi = fakePi();
bridge.default(pi);
assert.deepEqual([...pi.commands.keys()].sort(), [
  "fm-feishu-disable",
  "fm-feishu-status",
]);
assert(!pi.handlers.has("input") && !pi.handlers.has("tool_call") && !pi.handlers.has("turn_start"));
turnend.default(pi);
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
    getEntries() { return []; },
  },
  ui: { notify(message) { notices.push(String(message)); }, setStatus() {} },
  async reload() {},
};
await emit(pi, "session_start", { reason: "startup" }, ctx);
for (let attempt = 0; attempt < 100 && !existsSync(process.env.BRIDGE_LIFECYCLE_LOG); attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID]);
assert(existsSync(`${process.env.FM_HOME}/state/.pi-feishu-extension-loaded`), "post-session-start ownership signal did not publish the loaded marker");
const binding = JSON.parse(readFileSync(`${process.env.FM_HOME}/data/feishu/bindings/active.json`, "utf8"));
assert.equal(binding.session_id, process.env.SID);
assert.equal(binding.session_file_realpath, process.env.BRIDGE_SESSION_FILE);
assert.equal(binding.session_cwd_realpath, process.env.BRIDGE_SESSION);
events.emit("firstmate:session-start-settled", { reason: "startup" });
await emit(pi, "agent_start", {}, ctx);
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID], "repeated settled or agent_start boundary duplicated configured lifecycle reconciliation");
assert.deepEqual(readFileSync(process.env.BRIDGE_TRANSPORT_LOG, "utf8").trim().split("\n"), ["start generation=1"], "repeated settled or agent_start boundary duplicated transport startup");

writeFileSync(`${process.env.FM_HOME}/lock-mode`, "other\n");
await emit(pi, "session_shutdown", { reason: "reload" }, ctx);
rmSync(`${process.env.FM_HOME}/state/.pi-feishu-extension-loaded`);
pi = fakePi();
bridge.default(pi);
turnend.default(pi);
await emit(pi, "session_start", { reason: "reload" }, ctx);
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID], "reload bypassed the missing lock owner");
assert(!existsSync(`${process.env.FM_HOME}/state/.pi-feishu-extension-loaded`), "unowned reload published the loaded marker");
await emit(pi, "agent_start", {}, ctx);
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID], "post-reload wrong-owner agent_start activated the channel");
writeFileSync(`${process.env.FM_HOME}/lock-mode`, "owned\n");
await emit(pi, "agent_start", {}, ctx);
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID, process.env.SID], "first owned turn after reload did not converge the configured channel");
assert(existsSync(`${process.env.FM_HOME}/state/.pi-feishu-extension-loaded`), "first owned turn after reload did not publish the loaded marker");
assert.deepEqual(readFileSync(process.env.BRIDGE_TRANSPORT_LOG, "utf8").trim().split("\n"), ["start generation=1"], "reload recovery duplicated transport startup");

await pi.commands.get("fm-feishu-disable").handler("", ctx);
assert(existsSync(process.env.BRIDGE_TRANSPORT_LOG), notices.join("\n"));
assert.deepEqual(readFileSync(process.env.BRIDGE_TRANSPORT_LOG, "utf8").trim().split("\n"), ["start generation=1", "disable-config generation=1"]);
assert(notices.every((message) => !message.includes("refused")), notices.join("\n"));

rmSync(`${process.env.FM_HOME}/data/feishu`, { recursive: true });
rmSync(`${process.env.FM_HOME}/state/feishu`, { recursive: true });
rmSync(`${process.env.FM_HOME}/state/.pi-feishu-extension-loaded`);
writeFileSync(`${process.env.FM_HOME}/config/feishu.env`, "FM_FEISHU_ENABLED=false\n", { mode: 0o600 });
pi = fakePi();
bridge.default(pi);
turnend.default(pi);
await emit(pi, "session_start", { reason: "reload" }, ctx);
await emit(pi, "agent_start", {}, ctx);
assert(!existsSync(`${process.env.FM_HOME}/data/feishu`) && !existsSync(`${process.env.FM_HOME}/state/feishu`), "disabled public lifecycle created Feishu state");
assert.deepEqual(readFileSync(process.env.BRIDGE_LIFECYCLE_LOG, "utf8").trim().split("\n"), [process.env.SID, process.env.SID], "disabled public lifecycle reconciled a pairing");
assert.deepEqual(readFileSync(process.env.BRIDGE_TRANSPORT_LOG, "utf8").trim().split("\n"), ["start generation=1", "disable-config generation=1"], "disabled public lifecycle started a transport");
console.log("ok - local Pi bridge converges after delayed ownership and keeps only status and durable disable controls");
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
  const card = JSON.parse(payload.data.content);
  const markdown = card?.elements?.length === 1 && card.elements[0]?.tag === "markdown"
    ? card.elements[0].content
    : undefined;
  log({ type: "send", kind, uuid: payload.data.uuid, msgType: payload.data.msg_type, card, markdown, replyTo: payload.path?.message_id ?? null, receiveId: payload.data.receive_id ?? null });
  if (payload.data.msg_type !== "interactive" || typeof markdown !== "string" || card?.config?.wide_screen_mode !== true) {
    const error = new Error("unsupported outbound fixture format");
    error.response = { status: 400, data: { code: 230099 } };
    throw error;
  }
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
  if (mode === "unsupported-once" && mark && !existsSync(mark)) {
    writeFileSync(mark, "unsupported\n");
    if (lock) rmSync(lock, { recursive: true, force: true });
    return { code: 230099, msg: "unsupported interactive fixture" };
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
    if (process.env.FM_FAKE_SDK_AUTH_REJECT === "1") throw new Error(`credential rejected: ${options.appSecret}`);
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

write_feishu_config() {
  home=$1
  enabled=$2
  app_id=${3:-$APP_ID}
  app_secret=${4:-$APP_SECRET}
  open_id=${5:-ou_captain1234}
  chat_id=${6:-oc_chat1234}
  mkdir -p "$home/config"
  cat > "$home/config/feishu.env" <<EOF
FM_FEISHU_ENABLED=$enabled
FM_FEISHU_APP_ID=$app_id
FM_FEISHU_APP_SECRET=$app_secret
FM_FEISHU_CAPTAIN_OPEN_ID=$open_id
FM_FEISHU_P2P_CHAT_ID=$chat_id
EOF
  chmod 600 "$home/config/feishu.env"
}

run_config_check() {
  home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" bash bin/fm-feishu-transport.sh config-check
}

run_configured_lifecycle() {
  home=$1
  session_id=$2
  session_file=$3
  session_dir=$4
  boundary=${5:-null}
  shift 5 || true
  printf '{"sessionId":"%s","sessionFile":"%s","sessionCwd":"%s","headerId":"%s","headerCwd":"%s","outboundAfterEntryId":%s}\n' \
    "$session_id" "$session_file" "$session_dir" "$session_id" "$session_dir" "$boundary" |
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
      FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
      "$@" node bin/fm-feishu-lifecycle.mjs reconcile
}

owner_pid() {
  node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1])).pid))' \
    "$1/state/feishu/transport/owner.json"
}

wait_for_transport_phase() {
  home=$1
  expected=$2
  for _ in $(seq 1 150); do
    phase=$(FM_HOME="$home" node bin/fm-feishu-state.mjs status --public 2>/dev/null |
      node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).transport_phase||"")}catch{}})' || true)
    [ "$phase" = "$expected" ] && return 0
    sleep 0.03
  done
  return 1
}

INERT_CONFIG_HOME="$TMP_ROOT/config-inert-home"
INERT_CONFIG_SESSION="$TMP_ROOT/config-inert-session"
INERT_CONFIG_FILE="$INERT_CONFIG_SESSION/current.jsonl"
mkdir -p "$INERT_CONFIG_HOME/config" "$INERT_CONFIG_HOME/data" "$INERT_CONFIG_HOME/state" "$INERT_CONFIG_SESSION"
printf 'owned\n' > "$INERT_CONFIG_HOME/lock-mode"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$INERT_CONFIG_SESSION" > "$INERT_CONFIG_FILE"
[ "$(run_config_check "$INERT_CONFIG_HOME")" = '{"status":"absent"}' ] || fail "absent Feishu config did not report inert"
run_configured_lifecycle "$INERT_CONFIG_HOME" "$SID" "$INERT_CONFIG_FILE" "$INERT_CONFIG_SESSION" null \
  >"$TMP_ROOT/config-inert.out" 2>"$TMP_ROOT/config-inert.err"
[ ! -s "$TMP_ROOT/config-inert.out" ] && [ ! -s "$TMP_ROOT/config-inert.err" ] \
  || fail "absent Feishu config emitted startup chatter"
[ ! -e "$INERT_CONFIG_HOME/data/feishu" ] && [ ! -e "$INERT_CONFIG_HOME/state/feishu" ] \
  || fail "absent Feishu config created private channel state"

CONFIG_REFUSAL_HOME="$TMP_ROOT/config-refusal-home"
mkdir -p "$CONFIG_REFUSAL_HOME/config" "$CONFIG_REFUSAL_HOME/data" "$CONFIG_REFUSAL_HOME/state"
for body in \
  'FM_FEISHU_ENABLED=true' \
  'FM_FEISHU_ENABLED=true|FM_FEISHU_ENABLED=true' \
  'FM_FEISHU_ENABLED=true|FM_FEISHU_UNSUPPORTED=value'; do
  printf '%s\n' "$body" | tr '|' '\n' > "$CONFIG_REFUSAL_HOME/config/feishu.env"
  chmod 600 "$CONFIG_REFUSAL_HOME/config/feishu.env"
  if run_config_check "$CONFIG_REFUSAL_HOME" >"$TMP_ROOT/config-refusal.out" 2>"$TMP_ROOT/config-refusal.err"; then
    fail "malformed, duplicate, or unsupported Feishu config was accepted"
  fi
  grep -Fq "$APP_SECRET" "$TMP_ROOT/config-refusal.err" && fail "config refusal exposed a credential"
done
write_feishu_config "$CONFIG_REFUSAL_HOME" true
chmod 644 "$CONFIG_REFUSAL_HOME/config/feishu.env"
if run_config_check "$CONFIG_REFUSAL_HOME" >"$TMP_ROOT/config-mode.out" 2>"$TMP_ROOT/config-mode.err"; then
  fail "group-readable Feishu config was accepted"
fi
chmod 600 "$CONFIG_REFUSAL_HOME/config/feishu.env"
mv "$CONFIG_REFUSAL_HOME/config/feishu.env" "$CONFIG_REFUSAL_HOME/config/real.env"
ln -s real.env "$CONFIG_REFUSAL_HOME/config/feishu.env"
if run_config_check "$CONFIG_REFUSAL_HOME" >"$TMP_ROOT/config-symlink.out" 2>"$TMP_ROOT/config-symlink.err"; then
  fail "symlinked Feishu config was accepted"
fi
rm "$CONFIG_REFUSAL_HOME/config/feishu.env"
mv "$CONFIG_REFUSAL_HOME/config/real.env" "$CONFIG_REFUSAL_HOME/config/feishu.env"
if command -v setpriv >/dev/null 2>&1; then
  chmod 755 "$TMP_ROOT" "$CONFIG_REFUSAL_HOME" "$CONFIG_REFUSAL_HOME/config"
  if setpriv --reuid=65534 --regid=65534 --clear-groups \
    env FM_HOME="$CONFIG_REFUSAL_HOME" FM_ROOT_OVERRIDE="$ROOT" bash bin/fm-feishu-transport.sh config-check \
    >"$TMP_ROOT/config-owner.out" 2>"$TMP_ROOT/config-owner.err"; then
    fail "Feishu config owned by another user was accepted"
  fi
fi

AUTO_HOME="$TMP_ROOT/auto-home"
AUTO_SESSION_ONE="$TMP_ROOT/auto-session-one"
AUTO_SESSION_TWO="$TMP_ROOT/auto-session-two"
AUTO_FILE_ONE="$AUTO_SESSION_ONE/current.jsonl"
AUTO_FILE_TWO="$AUTO_SESSION_TWO/current.jsonl"
AUTO_SDK_LOG="$TMP_ROOT/auto-sdk.log"
mkdir -p "$AUTO_HOME/data" "$AUTO_HOME/state" "$AUTO_SESSION_ONE" "$AUTO_SESSION_TWO"
printf 'owned\n' > "$AUTO_HOME/lock-mode"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$AUTO_SESSION_ONE" > "$AUTO_FILE_ONE"
SECOND_SID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SECOND_SID" "$AUTO_SESSION_TWO" > "$AUTO_FILE_TWO"
write_feishu_config "$AUTO_HOME" true
: > "$AUTO_SDK_LOG"
run_configured_lifecycle "$AUTO_HOME" "$SID" "$AUTO_FILE_ONE" "$AUTO_SESSION_ONE" '"0000000a"' \
  FM_FAKE_SDK_LOG="$AUTO_SDK_LOG" >"$TMP_ROOT/auto-first.out" 2>"$TMP_ROOT/auto-first.err"
[ ! -s "$TMP_ROOT/auto-first.out" ] && [ ! -s "$TMP_ROOT/auto-first.err" ] \
  || fail "healthy automatic Feishu activation emitted success chatter"
wait_for_transport_phase "$AUTO_HOME" healthy || fail "automatic Feishu transport did not become healthy"
FIRST_OWNER=$(owner_pid "$AUTO_HOME")
AUTO_HOME="$AUTO_HOME" APP_SECRET="$APP_SECRET" node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readActiveBinding, readPairing } from "./bin/fm-feishu-state.mjs";
const pairing = readPairing(process.env.AUTO_HOME);
const binding = readActiveBinding(process.env.AUTO_HOME);
assert.equal(pairing.allowed_users[0], "ou_captain1234");
assert.equal(pairing.allowed_chats[0], "oc_chat1234");
assert.equal(pairing.managed_by, "local-config");
assert.equal(binding.generation, 1);
assert.equal(binding.bound_by, "local-config");
assert.equal(binding.outbound_after_entry_id, "0000000a");
assert(!JSON.stringify(pairing).includes(process.env.APP_SECRET));
assert(!JSON.stringify(binding).includes(process.env.APP_SECRET));
const owner = JSON.parse(readFileSync(`${process.env.AUTO_HOME}/state/feishu/transport/owner.json`, "utf8"));
assert(!JSON.stringify(owner).includes(process.env.APP_SECRET));
JS
tr '\0' '\n' < "/proc/$FIRST_OWNER/cmdline" | grep -Fq "$APP_SECRET" \
  && fail "Feishu App Secret appeared in the transport process title or arguments"
run_configured_lifecycle "$AUTO_HOME" "$SID" "$AUTO_FILE_ONE" "$AUTO_SESSION_ONE" '"0000000a"' \
  FM_FAKE_SDK_LOG="$AUTO_SDK_LOG" >"$TMP_ROOT/auto-repeat.out" 2>"$TMP_ROOT/auto-repeat.err"
SECOND_OWNER=$(owner_pid "$AUTO_HOME")
[ "$SECOND_OWNER" = "$FIRST_OWNER" ] || fail "idempotent activation replaced a healthy matching transport"
[ "$(FM_HOME="$AUTO_HOME" node -e 'import("./bin/fm-feishu-state.mjs").then(m=>process.stdout.write(String(m.readActiveBinding(process.env.FM_HOME).generation)))')" -eq 1 ] \
  || fail "idempotent activation incremented the binding generation"

run_configured_lifecycle "$AUTO_HOME" "$SECOND_SID" "$AUTO_FILE_TWO" "$AUTO_SESSION_TWO" '"0000000b"' \
  FM_FAKE_SDK_LOG="$AUTO_SDK_LOG" >"$TMP_ROOT/auto-rebind.out" 2>"$TMP_ROOT/auto-rebind.err"
wait_for_transport_phase "$AUTO_HOME" healthy || fail "configured session replacement did not recover transport health"
REBOUND_OWNER=$(owner_pid "$AUTO_HOME")
[ "$REBOUND_OWNER" != "$FIRST_OWNER" ] || fail "configured session replacement retained the prior transport generation"
kill -0 "$FIRST_OWNER" 2>/dev/null && fail "configured session replacement left the prior transport alive"
AUTO_HOME="$AUTO_HOME" SECOND_SID="$SECOND_SID" node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readActiveBinding } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.AUTO_HOME);
assert.equal(binding.generation, 2);
assert.equal(binding.session_id, process.env.SECOND_SID);
assert.equal(binding.outbound_after_entry_id, "0000000b");
JS

FM_HOME="$AUTO_HOME" FM_FEISHU_SILENT=1 bash bin/fm-feishu-transport.sh stop
run_configured_lifecycle "$AUTO_HOME" "$SECOND_SID" "$AUTO_FILE_TWO" "$AUTO_SESSION_TWO" '"0000000b"' \
  FM_FAKE_SDK_LOG="$AUTO_SDK_LOG" >"$TMP_ROOT/auto-recover.out" 2>"$TMP_ROOT/auto-recover.err"
wait_for_transport_phase "$AUTO_HOME" healthy || fail "configured lifecycle did not recover a stopped transport"
RECOVERED_OWNER=$(owner_pid "$AUTO_HOME")
[ "$RECOVERED_OWNER" != "$REBOUND_OWNER" ] || fail "transport recovery did not create a new verified owner"
[ "$(FM_HOME="$AUTO_HOME" node -e 'import("./bin/fm-feishu-state.mjs").then(m=>process.stdout.write(String(m.readActiveBinding(process.env.FM_HOME).generation)))')" -eq 2 ] \
  || fail "transport-only recovery changed the binding generation"

FM_HOME="$AUTO_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_FEISHU_LOCK_STATUS_SCRIPT="$LOCK_SCRIPT" \
  FM_FEISHU_SILENT=1 bash bin/fm-feishu-transport.sh disable-config
[ "$(run_config_check "$AUTO_HOME")" = '{"status":"disabled"}' ] || fail "explicit local disable did not persist in config/feishu.env"
[ ! -e "$AUTO_HOME/state/feishu/transport/owner.json" ] || fail "explicit local disable left a transport owner"
[ "$(FM_HOME="$AUTO_HOME" node -e 'import("./bin/fm-feishu-state.mjs").then(m=>process.stdout.write(m.readActiveBinding(process.env.FM_HOME).status))')" = disabled ] \
  || fail "explicit local disable did not retire the active binding"
run_configured_lifecycle "$AUTO_HOME" "$SECOND_SID" "$AUTO_FILE_TWO" "$AUTO_SESSION_TWO" '"0000000b"' \
  FM_FAKE_SDK_LOG="$AUTO_SDK_LOG" >"$TMP_ROOT/auto-disabled.out" 2>"$TMP_ROOT/auto-disabled.err"
[ ! -e "$AUTO_HOME/state/feishu/transport/owner.json" ] || fail "disabled config restarted the transport"

REJECT_HOME="$TMP_ROOT/reject-home"
REJECT_SESSION="$TMP_ROOT/reject-session"
REJECT_FILE="$REJECT_SESSION/current.jsonl"
mkdir -p "$REJECT_HOME/data" "$REJECT_HOME/state" "$REJECT_SESSION"
printf 'owned\n' > "$REJECT_HOME/lock-mode"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$SID" "$REJECT_SESSION" > "$REJECT_FILE"
write_feishu_config "$REJECT_HOME" true
if run_configured_lifecycle "$REJECT_HOME" "$SID" "$REJECT_FILE" "$REJECT_SESSION" null \
  FM_FAKE_SDK_AUTH_REJECT=1 >"$TMP_ROOT/reject.out" 2>"$TMP_ROOT/reject.err"; then
  fail "credential-rejected Feishu config activated"
fi
grep -Fq "$APP_SECRET" "$TMP_ROOT/reject.out" "$TMP_ROOT/reject.err" \
  && fail "credential rejection exposed the App Secret"
[ ! -e "$REJECT_HOME/data/feishu" ] && [ ! -e "$REJECT_HOME/state/feishu" ] \
  || fail "credential rejection changed Feishu binding state before validation"

pass "secure config parsing and automatic Feishu lifecycle converge silently and fail closed"

write_feishu_config "$TRANSPORT_HOME" true
FM_HOME="$TRANSPORT_HOME" SESSION_FILE="$TRANSPORT_FILE" SESSION_DIR="$TRANSPORT_SESSION" SID="$SID" APP_FINGERPRINT="$APP_FINGERPRINT" TOUCH_SENTINEL="$TOUCH_SENTINEL" node --input-type=module <<'JS'
import { bindSession, createPairing, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const home = process.env.FM_HOME;
createPairing(home, { appIdFingerprint: process.env.APP_FINGERPRINT, allowedUser: "ou_captain1234", allowedChat: "oc_chat1234" });
const binding = bindSession(home, { sessionId: process.env.SID, sessionFile: process.env.SESSION_FILE, sessionCwd: process.env.SESSION_DIR, headerId: process.env.SID, headerCwd: process.env.SESSION_DIR });
const markdown = [
  "# Markdown reply",
  "",
  'Special characters: "quotes", \\ backslash, <tag>, &, and snowman ☃.',
  "",
  "[full link](https://example.test/kept?x=1&y=two) and `inline *code*`.",
  "",
  "```sh",
  `printf '%s\\n' 'literal $(touch ${process.env.TOUCH_SENTINEL})'`,
  "```",
].join("\n");
const result = registerAssistantOutbound(home, {
  text: markdown,
  assistantEntryId: "feed0001",
  sessionOrder: 1,
  sessionEntryTimestamp: "2026-08-12T00:00:01.000Z",
  sessionId: binding.session_id,
  bindingGeneration: binding.generation,
});
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS

BOOTSTRAP_OUT=$(FM_HOME="$TRANSPORT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_FEISHU_SDK_MODULE="$MOCK_SDK" bash bin/fm-bootstrap.sh)
printf '%s\n' "$BOOTSTRAP_OUT" | grep -q '^FEISHU:' \
  && fail "healthy configured Feishu startup emitted success chatter"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'ou_captain1234' \
  && fail "session-start Feishu health leaked the allowlisted open_id"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq 'oc_chat1234' \
  && fail "session-start Feishu health leaked the bound chat_id"
printf '%s\n' "$BOOTSTRAP_OUT" | grep -Fq "$APP_SECRET" \
  && fail "session-start Feishu health leaked the SDK app secret"

INERT_HOME="$TMP_ROOT/sdk-inert-home"
INERT_SDK_LOG="$TMP_ROOT/inert-sdk.log"
mkdir -p "$INERT_HOME/data" "$INERT_HOME/state"
FM_HOME="$INERT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FAKE_SDK_LOG="$INERT_SDK_LOG" node bin/fm-feishu-transport.mjs run --once \
  >"$TMP_ROOT/inert.out" 2>"$TMP_ROOT/inert.err"
[ ! -e "$INERT_SDK_LOG" ] || fail "unconfigured transport imported or initialized the SDK"

: > "$SDK_LOG"
write_feishu_config "$TRANSPORT_HOME" true cli_ffffffffffffffff
if PATH="$FAKE_BIN:$PATH" FM_HOME="$TRANSPORT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FAKE_SDK_LOG="$SDK_LOG" \
  node bin/fm-feishu-transport.mjs run --once >"$TMP_ROOT/app-mismatch.out" 2>"$TMP_ROOT/app-mismatch.err"; then
  fail "transport accepted an SDK app fingerprint mismatch"
fi
[ ! -s "$SDK_LOG" ] || fail "transport imported the SDK before validating the local app fingerprint"
[ ! -e "$LARK_SENTINEL" ] || fail "direct SDK transport executed lark-cli"

: > "$SDK_LOG"
write_feishu_config "$TRANSPORT_HOME" true
if PATH="$FAKE_BIN:$PATH" FM_HOME="$TRANSPORT_HOME" FM_FEISHU_SDK_MODULE="$MOCK_SDK" FM_FEISHU_SDK_TEST_MODE=1 \
  FM_FAKE_SDK_LOG="$SDK_LOG" FM_FAKE_SDK_CHAT_MODE=group \
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
if ! FM_HOME="$TRANSPORT_HOME" node --input-type=module - "$SDK_LOG" "$APP_SECRET" <<'JS'
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const [logPath, secret] = process.argv.slice(2);
const rows = readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse);
const sends = rows.filter((row) => row.type === "send");
const outboxDir = join(process.env.FM_HOME, "state", "feishu", "outbox");
const outbox = readdirSync(outboxDir).filter((name) => name.endsWith(".json")).map((name) => JSON.parse(readFileSync(join(outboxDir, name), "utf8"))).find((record) => record.assistant_entry_id === "feed0001");
if (!outbox || sends.length !== 2 || new Set(sends.map((row) => row.uuid)).size !== 1) process.exit(1);
if (sends.some((row) => row.kind !== "create" || row.receiveId !== "oc_chat1234" || row.replyTo !== null || row.msgType !== "interactive")) process.exit(1);
if (sends.some((row) => row.markdown !== outbox.text || row.card?.elements?.length !== 1 || row.card.elements[0]?.tag !== "markdown" || row.card?.config?.wide_screen_mode !== true)) process.exit(1);
if (!sends.every((row) => row.markdown.includes("\n") && row.markdown.includes("[full link](https://example.test/kept?x=1&y=two)") && row.markdown.includes("`inline *code*`") && row.markdown.includes("```sh"))) process.exit(1);
if (!rows.some((row) => row.type === "ws-start") || !rows.some((row) => row.type === "client" && row.hasSecret === true) || rows.some((row) => JSON.stringify(row).includes(secret))) process.exit(1);
JS
then
  fail "SDK Markdown card encoding, canonical bound-chat message.create, stable UUID, or credential-redaction evidence was wrong"
fi
[ "$(FM_HOME="$TRANSPORT_HOME" node bin/fm-feishu-state.mjs status --public | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).outbound_pending)))')" -eq 0 ] \
  || fail "SDK success did not publish a durable outbound receipt"
[ -n "$(find "$TRANSPORT_HOME/state/feishu/quarantine" -type f -name '*.json' -print -quit)" ] \
  || fail "SDK boundary did not durably refuse unauthorized identity/chat events"

FM_HOME="$TRANSPORT_HOME" SESSION_ID="$SID" node --input-type=module <<'JS'
import { readActiveBinding, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.FM_HOME);
const result = registerAssistantOutbound(process.env.FM_HOME, { text: "Unsupported delivery keeps **Markdown** with `code` and no plain-text fallback.", assistantEntryId: "feed0002", sessionOrder: 2, sessionEntryTimestamp: "2026-08-12T00:00:02.000Z", sessionId: process.env.SESSION_ID, bindingGeneration: binding.generation });
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS
rm -f "$SDK_SEND_MARK"
: > "$SDK_LOG"
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=unsupported-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
sleep 1.1
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=unsupported-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
# shellcheck disable=SC2016 # Backticks are literal JavaScript fixture data.
node -e 'const fs=require("fs");const sends=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse).filter(r=>r.type==="send");if(sends.length!==2||new Set(sends.map(r=>r.uuid)).size!==1||sends.some(r=>r.msgType!=="interactive"||r.markdown!=="Unsupported delivery keeps **Markdown** with `code` and no plain-text fallback."||Object.hasOwn(r.card,"text")))process.exit(1)' "$SDK_LOG" \
  || fail "an unsupported Markdown delivery changed payload type, content, or stable retry identity"

FM_HOME="$TRANSPORT_HOME" SESSION_ID="$SID" node --input-type=module <<'JS'
import { readActiveBinding, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.FM_HOME);
const result = registerAssistantOutbound(process.env.FM_HOME, { text: "server delayed SDK retry", assistantEntryId: "feed0003", sessionOrder: 3, sessionEntryTimestamp: "2026-08-12T00:00:03.000Z", sessionId: process.env.SESSION_ID, bindingGeneration: binding.generation });
if (result.status !== "registered") throw new Error(JSON.stringify(result));
JS
rm -f "$SDK_SEND_MARK"
: > "$SDK_LOG"
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=rate-limit-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
sleep 1.1
env PATH="$FAKE_BIN:$PATH" "${COMMON_SDK_ENV[@]}" FM_FAKE_SDK_SEND_MODE=rate-limit-once FM_FEISHU_ONCE_SETTLE_MS=20 \
  node bin/fm-feishu-transport.mjs run --once
node -e 'const fs=require("fs");const sends=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse).filter(r=>r.type==="send");if(sends.length!==2||sends[1].at-sends[0].at<900||new Set(sends.map(r=>r.uuid)).size!==1||sends.some(r=>r.msgType!=="interactive"))process.exit(1)' "$SDK_LOG" \
  || fail "SDK Retry-After mapping shortened the delay, changed UUID, or fell back from Markdown"

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
import { readActiveBinding, registerAssistantOutbound } from "./bin/fm-feishu-state.mjs";
const binding = readActiveBinding(process.env.FM_HOME);
const text = [
  "Chunk one has **bold** and `inline code`.",
  "",
  "[chunk-safe link](https://example.test/chunk-safe)",
  "",
  "```js",
  'const value = "<&>";',
  "```",
  "",
  "Multiline tail ☃.",
].join("\n");
const result = registerAssistantOutbound(process.env.FM_HOME, { text, assistantEntryId: "feed0004", sessionOrder: 4, sessionEntryTimestamp: "2026-08-12T00:00:04.000Z", sessionId: process.env.SESSION_ID, bindingGeneration: binding.generation, maxChunkBytes: 60 });
if (result.status !== "registered" || result.chunks < 2) throw new Error(JSON.stringify(result));
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
FM_HOME="$TRANSPORT_HOME" node --input-type=module - "$SDK_LOG" <<'JS'
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const rows = readFileSync(process.argv[2], "utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse);
const sends = rows.filter((row) => row.type === "send");
const outboxDir = join(process.env.FM_HOME, "state", "feishu", "outbox");
const outbox = readdirSync(outboxDir).filter((name) => name.endsWith(".json")).map((name) => JSON.parse(readFileSync(join(outboxDir, name), "utf8"))).find((record) => record.assistant_entry_id === "feed0004");
assert(outbox && outbox.chunks.length > 1, "multi-chunk Markdown outbox was absent");
assert.equal(sends.length, outbox.chunks.length, "one Markdown card was not sent per deterministic chunk");
assert.equal(sends.map((row) => row.markdown).join(""), outbox.text, "Markdown card chunks changed finalized Assistant text");
assert.deepEqual(sends.map((row) => row.uuid), outbox.chunks.map((chunk) => chunk.idempotency_key), "Markdown chunk delivery changed stable identities or order");
assert(sends.every((row) => row.msgType === "interactive" && row.card?.elements?.length === 1 && row.card.elements[0]?.tag === "markdown"), "a chunk did not use the supported Markdown card envelope");
JS

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

pass "official-SDK long-connection transport is inert, identity-fenced, deduplicated, and durably serialized Markdown outbound"
