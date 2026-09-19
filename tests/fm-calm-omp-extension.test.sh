#!/usr/bin/env bash
# Focused preference, /calm persistence, operational-row hide/show, thinking
# collapse, and Calm-off restore checks for OMP Calm hide-ceremony.
# Live TUI coverage stays opt-in via FM_OMP_LIVE_E2E (tests/fm-omp-primary-live-e2e.test.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-omp-extension)
EXT="$ROOT/.omp/extensions/fm-calm.ts"
OPERATIONAL_USER="$ROOT/.omp/extensions/lib/fm-calm-operational-user.ts"
ASSISTANT_THINKING="$ROOT/.omp/extensions/lib/fm-calm-assistant-thinking.ts"
PREFERENCE="$ROOT/.pi/extensions/lib/fm-calm-preference.ts"
PERSISTENCE="$ROOT/.pi/extensions/lib/fm-calm-persistence.ts"
VISIBILITY_CORE="$ROOT/.pi/extensions/lib/fm-calm-visibility-core.ts"
PRESERVATION="$ROOT/.pi/extensions/lib/fm-calm-preservation.ts"
OPERATIONAL_INPUT_TS="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
OPERATIONAL_INPUT_SH="$ROOT/bin/fm-operational-input.sh"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

install_omp_calm_fixture() {  # <repo>
  local repo=$1
  mkdir -p \
    "$repo/.omp/extensions/lib" \
    "$repo/.pi/extensions/lib" \
    "$repo/bin" \
    "$repo/node_modules/@oh-my-pi/pi-coding-agent" \
    "$repo/node_modules/@oh-my-pi/pi-tui"
  cp "$EXT" "$repo/.omp/extensions/fm-calm.ts"
  cp "$OPERATIONAL_USER" "$ASSISTANT_THINKING" "$repo/.omp/extensions/lib/"
  cp "$PREFERENCE" "$VISIBILITY_CORE" "$PRESERVATION" "$OPERATIONAL_INPUT_TS" "$repo/.pi/extensions/lib/"
  cp "$PERSISTENCE" "$repo/.pi/extensions/lib/fm-calm-persistence.ts"
  # Preservation is a symlink in the real tree; copy the target bytes.
  cp "$ROOT/.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts" "$repo/.pi/extensions/lib/fm-calm-preservation.ts"
  cp "$OPERATIONAL_INPUT_SH" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '%s\n' '{"type":"module"}' >"$repo/package.json"
  printf '%s\n' '{"name":"@oh-my-pi/pi-coding-agent","type":"module","exports":"./index.js"}' \
    >"$repo/node_modules/@oh-my-pi/pi-coding-agent/package.json"
  printf '%s\n' '{"name":"@oh-my-pi/pi-tui","type":"module","exports":"./index.js"}' \
    >"$repo/node_modules/@oh-my-pi/pi-tui/package.json"
  cat >"$repo/node_modules/@oh-my-pi/pi-tui/index.js" <<'JS'
export class Container {
  children = [];
  addChild(child) { this.children.push(child); }
  render() { return []; }
}
export class Box extends Container {}
JS
  cat >"$repo/node_modules/@oh-my-pi/pi-coding-agent/index.js" <<'JS'
export class Container {
  children = [];
  addChild(child) { this.children.push(child); }
  render() { return this.children.flatMap((c) => c.render?.(80) ?? []); }
}
export class UserMessageComponent {
  constructor(text, synthetic = false) {
    this.text = text;
    this.synthetic = synthetic;
  }
  render(width) {
    return [`user:${this.text}`.slice(0, Math.max(1, width))];
  }
}
export class AssistantMessageComponent {
  constructor(hideThinkingBlock = false) {
    this.hideThinkingBlock = hideThinkingBlock;
    this.lastMessage = undefined;
    this.lastOptions = undefined;
  }
  setHideThinkingBlock(hide) { this.hideThinkingBlock = hide; }
  invalidate() {
    if (this.lastMessage) this.updateContent(this.lastMessage);
  }
  updateContent(message, options) {
    this.lastMessage = message;
    this.lastOptions = options;
    this.rendered = [];
    for (const block of message.content) {
      if (block.type === "thinking" && this.hideThinkingBlock) continue;
      if (block.type === "text") this.rendered.push(`text:${block.text}`);
      if (block.type === "thinking") this.rendered.push(`thinking:${block.thinking ?? block.text ?? ""}`);
    }
  }
}
export class InteractiveMode {
  constructor() {
    this.ctx = {
      chatContainer: { children: [], addChild(c) { this.children.push(c); } },
      transcriptMessageComponents: new Map(),
      getUserMessageText(message) {
        if (typeof message.content === "string") return message.content;
        return message.content.filter((b) => b.type === "text").map((b) => b.text).join("");
      },
    };
  }
  addMessageToChat(message, options) {
    if (message.role !== "user" && message.role !== "developer") return;
    const text = this.ctx.getUserMessageText(message);
    if (!text) return;
    const component = new UserMessageComponent(
      text,
      message.role === "developer" ? true : message.synthetic ?? false,
    );
    this.ctx.transcriptMessageComponents.set(message, component);
    this.ctx.chatContainer.addChild(component);
  }
}
JS
}

record_omp_version_evidence() {
  local version=$1 context=$2
  [ -n "$version" ] || fail "$context could not determine the installed OMP version"
}

test_preference_read_write_contract() {
  local fixture out status
  fixture="$TMP_ROOT/preference"
  install_omp_calm_fixture "$fixture"
  out=$(cd "$fixture" && PREF="$fixture/.pi/extensions/lib/fm-calm-preference.ts" PERSIST="$fixture/.pi/extensions/lib/fm-calm-persistence.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync, mkdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
const pref = await import(pathToFileURL(process.env.PREF).href);
const persistence = await import(pathToFileURL(process.env.PERSIST).href);
const home = resolve("home");
mkdirSync(`${home}/config`, { recursive: true });
const path = pref.calmPreferencePath({ FM_HOME: home }, resolve("."));
if (persistence.loadCalmPreference(path) !== false) throw new Error("absent preference must read off");
if (pref.parseCalmPreference(undefined) !== false) throw new Error("undefined must read off");
if (pref.parseCalmPreference("nope\n") !== false) throw new Error("unrecognized must read off");
if (pref.parseCalmPreference("on\n") !== true) throw new Error("on must read on");
if (pref.parseCalmPreference("max\n") !== true) throw new Error("legacy max must read on");
if (pref.serializeCalmPreference(true) !== "on\n") throw new Error("serialize on");
if (pref.serializeCalmPreference(false) !== "off\n") throw new Error("serialize off");
persistence.persistCalmPreference(path, true);
if (readFileSync(path, "utf8") !== "on\n") throw new Error("persist did not write on\\n");
const mode = statSync(path).mode & 0o777;
if (mode !== 0o600) throw new Error(`preference mode must be 0600, got ${mode.toString(8)}`);
persistence.persistCalmPreference(path, false);
if (readFileSync(path, "utf8") !== "off\n") throw new Error("persist did not write off\\n");
JS
)
  status=$?
  expect_code 0 "$status" "preference contract: $out"
  [ -z "$out" ] || fail "preference contract printed output: $out"
  pass "OMP Calm preference parse/serialize/atomic write matches the shared config/calm contract"
}

test_calm_command_persists_and_reloads() {
  local fixture home out status version
  if ! command -v omp >/dev/null 2>&1; then
    echo "skip: omp not installed for version evidence (portable contract still runs under Node)"
  else
    version=$(omp --version 2>/dev/null | head -1)
    record_omp_version_evidence "$version" "OMP calm public-API probe"
  fi
  fixture="$TMP_ROOT/command"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home/config"
  out=$(cd "$fixture" && FM_HOME="$home" EXT="$fixture/.omp/extensions/fm-calm.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
let calmCommand;
const messageRenderers = new Map();
let thinkingRenderer;
const pi = {
  pi: { Container: class { render() { return []; } } },
  events: { emit() {} },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerMessageRenderer(type, renderer) { messageRenderers.set(type, renderer); },
  registerAssistantThinkingRenderer(renderer) { thinkingRenderer = renderer; },
};
const mod = await import(`${pathToFileURL(process.env.EXT).href}?t=${Date.now()}`);
mod.default(pi);
if (!calmCommand) throw new Error("/calm was not registered");
if (!handlers.has("session_start")) throw new Error("session_start was not registered");
if (messageRenderers.size < 1) throw new Error("registerMessageRenderer was not used");
if (typeof thinkingRenderer !== "function") throw new Error("registerAssistantThinkingRenderer was not used");
const ui = {
  notify() {},
  getToolsExpanded() { return false; },
  setToolsExpanded() {},
  setStatus() {},
};
const ctx = { ui };
handlers.get("session_start")({ type: "session_start" }, ctx);
const preference = `${process.env.FM_HOME}/config/calm`;
if (existsSync(preference)) throw new Error("absent preference must not create the file on session_start");
await calmCommand.handler("", ctx);
if (readFileSync(preference, "utf8") !== "on\n") throw new Error("/calm did not persist on");
await calmCommand.handler("", ctx);
if (readFileSync(preference, "utf8") !== "off\n") throw new Error("/calm did not persist off");
// Reload from disk on a fresh session_start after an external write.
const { writeFileSync } = await import("node:fs");
writeFileSync(preference, "on\n", { mode: 0o600 });
const vis = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-visibility-core.ts`).href);
vis.setCalmPresentation(false);
handlers.get("session_start")({ type: "session_start" }, ctx);
if (!vis.calmPresentationIsActive()) throw new Error("session_start did not reload on from disk");
JS
)
  status=$?
  expect_code 0 "$status" "calm command contract: $out"
  [ -z "$out" ] || fail "calm command contract printed output: $out"
  pass "OMP /calm persists config/calm and session_start reloads it; public renderer seams register"
}

test_operational_row_hide_show_and_thinking_collapse() {
  local fixture home out status encoded
  fixture="$TMP_ROOT/hide"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home/config"
  printf 'on\n' >"$home/config/calm"
  encoded=$(printf 'FIRSTMATE WATCHER WAKE: signal: omp-calm\n' | "$OPERATIONAL_INPUT_SH" encode watcher)
  out=$(cd "$fixture" && FM_HOME="$home" EXT="$fixture/.omp/extensions/fm-calm.ts" \
    OPERATIONAL_TEXT="$encoded" GENUINE_TEXT="please review the PR" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const handlers = new Map();
let calmCommand;
const pi = {
  pi: { Container: class { render() { return []; } } },
  events: { emit() {} },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerMessageRenderer() {},
  registerAssistantThinkingRenderer() {},
};
const mod = await import(`${pathToFileURL(process.env.EXT).href}?hide=${Date.now()}`);
mod.default(pi);
const ui = {
  notify() {},
  getToolsExpanded() { return false; },
  setToolsExpanded() {},
  setStatus() {},
};
handlers.get("session_start")({ type: "session_start" }, { ui });

const mode = new Agent.InteractiveMode();
const operational = { role: "user", content: process.env.OPERATIONAL_TEXT };
const genuine = { role: "user", content: process.env.GENUINE_TEXT };
const realOmpPresentationContext = {
  chatContainer: { children: [], addChild(child) { this.children.push(child); } },
  transcriptMessageComponents: new Map(),
  getUserMessageText: mode.ctx.getUserMessageText,
};
Agent.InteractiveMode.prototype.addMessageToChat.call(realOmpPresentationContext, operational);
const realOmpOperational = realOmpPresentationContext.chatContainer.children.at(-1);
if (realOmpOperational.render(80).length !== 0) {
  throw new Error("Calm-on must hide operational rows for OMP's presentation-context receiver");
}
mode.addMessageToChat(operational);
mode.addMessageToChat(genuine);
const [opComponent, genuineComponent] = mode.ctx.chatContainer.children;
if (opComponent.render(80).length !== 0) {
  throw new Error(`Calm-on must hide operational rows, got ${JSON.stringify(opComponent.render(80))}`);
}
if (genuineComponent.render(80).length === 0) {
  throw new Error("Calm-on must keep genuine user prompts visible");
}

const assistant = new Agent.AssistantMessageComponent();
assistant.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "short note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if ((assistant.rendered || []).some((line) => line.startsWith("thinking:"))) {
  throw new Error(`Calm-on must not render thinking, got ${JSON.stringify(assistant.rendered)}`);
}
if ((assistant.rendered || []).some((line) => line === "text:short note")) {
  throw new Error(`Calm-on must hide short mid-turn working notes, got ${JSON.stringify(assistant.rendered)}`);
}
assistant.updateContent({
  content: [
    { type: "text", text: "streaming short note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if ((assistant.rendered || []).some((line) => line === "text:streaming short note")) {
  throw new Error(`Calm-on must hide streaming mid-turn working notes, got ${JSON.stringify(assistant.rendered)}`);
}

assistant.invalidate();
await calmCommand.handler("", { ui });
if (opComponent.render(80).length === 0) {
  throw new Error("Calm-off must restore operational rows");
}
if (!(assistant.rendered || []).some((line) => line === "text:streaming short note")) {
  throw new Error(`Calm-off must restore the hidden working note, got ${JSON.stringify(assistant.rendered)}`);
}
if (assistant.lastOptions?.transient !== true) {
  throw new Error(`Calm-off must preserve transient update options, got ${JSON.stringify(assistant.lastOptions)}`);
}
assistant.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "stale note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if (!(assistant.rendered || []).some((line) => line === "text:stale note")) {
  throw new Error("Calm-off must keep a newly rendered working note visible");
}
await calmCommand.handler("", { ui });
if ((assistant.rendered || []).some((line) => line === "text:stale note")) {
  throw new Error("Calm-on must hide an existing working note");
}
handlers.get("session_start")({ type: "session_start" }, { ui });
await calmCommand.handler("", { ui });
if ((assistant.rendered || []).some((line) => line === "text:stale note")) {
  throw new Error("a new session must not restore an old assistant component");
}
assistant.updateContent({
  stopReason: "stop",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "final answer for the captain" },
  ],
});
if (!(assistant.rendered || []).some((line) => line.startsWith("thinking:"))) {
  throw new Error(`Calm-off must show thinking again, got ${JSON.stringify(assistant.rendered)}`);
}
JS
)
  status=$?
  expect_code 0 "$status" "hide/show contract: $out"
  [ -z "$out" ] || fail "hide/show contract printed output: $out"
  pass "OMP Calm hides operational rows and thinking while on, and restores both when toggled off"
}

test_working_note_via_omp_events() {
  local fixture home out status
  fixture="$TMP_ROOT/working-note-events"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home/config"
  printf 'on\n' >"$home/config/calm"
  out=$(cd "$fixture" && FM_HOME="$home" EXT="$fixture/.omp/extensions/fm-calm.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const handlers = new Map();
let calmCommand;
const pi = {
  pi: { Container: class { render() { return []; } } },
  events: { emit() {} },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerMessageRenderer() {},
  registerAssistantThinkingRenderer() {},
};
const mod = await import(`${pathToFileURL(process.env.EXT).href}?note=${Date.now()}`);
mod.default(pi);
for (const event of ["message_start", "message_update", "message_end"]) {
  if (typeof handlers.get(event) !== "function") {
    throw new Error(`Calm must observe OMP ${event} to know a message was mid-turn`);
  }
}
const ui = {
  notify() {},
  getToolsExpanded() { return false; },
  setToolsExpanded() {},
  setStatus() {},
};
const ctx = { ui };
handlers.get("session_start")({ type: "session_start" }, ctx);

// OMP 18.1.17 hands AssistantMessageComponent the derived before-tools message
// (no toolCall, stopReason forced to "stop"); the unfiltered message only
// reaches the extension event stream. Both orders must hide the settled note.
const FULL = {
  role: "assistant",
  stopReason: "toolUse",
  timestamp: 1001,
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "CALM_WORKING_NOTE" },
    { type: "toolCall" },
  ],
};
const BEFORE = {
  role: "assistant",
  stopReason: "stop",
  timestamp: 1001,
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "CALM_WORKING_NOTE" },
  ],
};
const rendered = (component) => component.rendered || [];
const hasNote = (component) => rendered(component).some((line) => line === "text:CALM_WORKING_NOTE");

const settled = new Agent.AssistantMessageComponent();
settled.updateContent(BEFORE, { transient: true });
handlers.get("message_end")({ type: "message_end", message: FULL }, ctx);
settled.updateContent(BEFORE, { transient: true });
if (hasNote(settled)) {
  throw new Error(`Calm-on must hide the derived before-tools working note, got ${JSON.stringify(rendered(settled))}`);
}
if (rendered(settled).some((line) => line.startsWith("thinking:"))) {
  throw new Error(`Calm-on must not render thinking, got ${JSON.stringify(rendered(settled))}`);
}

const streaming = new Agent.AssistantMessageComponent();
streaming.updateContent(BEFORE, { transient: true });
handlers.get("message_update")({ type: "message_update", message: FULL }, ctx);
if (hasNote(streaming)) {
  throw new Error(`Calm-on must collapse an already-rendered working note on the OMP update, got ${JSON.stringify(rendered(streaming))}`);
}

const FINAL = {
  role: "assistant",
  stopReason: "stop",
  timestamp: 2002,
  content: [{ type: "text", text: "CALM_FINAL" }],
};
const final = new Agent.AssistantMessageComponent();
final.updateContent(FINAL, { transient: true });
handlers.get("message_end")({ type: "message_end", message: FINAL }, ctx);
final.updateContent(FINAL, { transient: true });
if (!rendered(final).some((line) => line === "text:CALM_FINAL")) {
  throw new Error(`Calm-on must keep a genuine final reply visible, got ${JSON.stringify(rendered(final))}`);
}

await calmCommand.handler("", ctx);
if (!hasNote(settled)) {
  throw new Error(`Calm-off must restore the hidden working note, got ${JSON.stringify(rendered(settled))}`);
}
JS
)
  status=$?
  expect_code 0 "$status" "working note via OMP events: $out"
  [ -z "$out" ] || fail "working note via OMP events printed output: $out"
  pass "OMP Calm hides the derived before-tools working note using OMP's own assistant message events"
}

test_double_install_keeps_shared_state() {
  local fixture home out status
  fixture="$TMP_ROOT/double-install"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home/config"
  printf 'on\n' >"$home/config/calm"
  out=$(cd "$fixture" && FM_HOME="$home" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const thinking = await import(pathToFileURL(`${process.cwd()}/.omp/extensions/lib/fm-calm-assistant-thinking.ts`).href);
const vis = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-visibility-core.ts`).href);
// The same process can load the extension twice (`-e` plus the cwd auto-discovery).
// Both installs must share one remembered component set so a later /calm toggle
// refreshes rows the first install already saw, and a session swap clears them all.
thinking.installOmpCalmAssistantThinking();
thinking.installOmpCalmAssistantThinking();
vis.setCalmPresentation(true);
const component = new Agent.AssistantMessageComponent();
component.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "short note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if ((component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("Calm-on must hide the working note after a double install");
}
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if (!(component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("a second install lost the shared remembered component set");
}
vis.setCalmPresentation(true);
const fresh = new Agent.AssistantMessageComponent();
fresh.updateContent({
  stopReason: "toolUse",
  content: [{ type: "text", text: "fresh note" }, { type: "toolCall" }],
}, { transient: true });
if ((fresh.rendered || []).some((line) => line === "text:fresh note")) {
  throw new Error("Calm-on must hide a fresh working note");
}
thinking.resetOmpCalmThinkingRememberedRows();
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if ((fresh.rendered || []).some((line) => line === "text:fresh note")) {
  throw new Error("reset must clear the shared remembered component set before a session swap");
}
JS
)
  status=$?
  expect_code 0 "$status" "double install contract: $out"
  [ -z "$out" ] || fail "double install contract printed output: $out"
  pass "a second OMP Calm install in one process keeps one shared remembered component set"
}

test_retry_recovery_keeps_original_note() {
  local fixture out status
  fixture="$TMP_ROOT/retry-recovery"
  install_omp_calm_fixture "$fixture"
  out=$(cd "$fixture" && node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const thinking = await import(pathToFileURL(`${process.cwd()}/.omp/extensions/lib/fm-calm-assistant-thinking.ts`).href);
const vis = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-visibility-core.ts`).href);
thinking.installOmpCalmAssistantThinking();
vis.setCalmPresentation(true);
const component = new Agent.AssistantMessageComponent();
component.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "short note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if ((component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("Calm-on must hide the working note before retry recovery");
}
// OMP 18.1.17 applyRetryRecovery spreads the stored presentation message into a
// new object, so a message-identity check would treat it as a fresh original.
component.updateContent({ ...component.lastMessage, retryRecovery: { reason: "transport" } });
if ((component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("Calm-on must keep the working note hidden during retry recovery");
}
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if (!(component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("Calm-off must restore the working note after retry recovery");
}
if (component.lastMessage?.retryRecovery?.reason !== "transport") {
  throw new Error("Calm-off must preserve retry-recovery metadata");
}
if (component.lastOptions?.transient !== true) {
  throw new Error("Calm-off must preserve the original transient update options");
}
JS
)
  status=$?
  expect_code 0 "$status" "retry recovery contract: $out"
  [ -z "$out" ] || fail "retry recovery contract printed output: $out"
  pass "OMP retry recovery keeps the unfiltered original so Calm-off restores hidden working notes"
}

test_native_hide_thinking_is_additive() {
  local fixture out status
  fixture="$TMP_ROOT/native-hide-thinking"
  install_omp_calm_fixture "$fixture"
  out=$(cd "$fixture" && node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const thinking = await import(pathToFileURL(`${process.cwd()}/.omp/extensions/lib/fm-calm-assistant-thinking.ts`).href);
const vis = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-visibility-core.ts`).href);
thinking.installOmpCalmAssistantThinking();
const message = {
  stopReason: "stop",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "answer for the captain" },
  ],
};
const showsThinking = (component) => (component.rendered || []).some((line) => line.startsWith("thinking:"));
const trackWrites = (component) => {
  let writes = 0;
  const original = component.setHideThinkingBlock.bind(component);
  component.setHideThinkingBlock = (value) => {
    writes += 1;
    original(value);
  };
  return () => writes;
};

// Calm off must be strictly additive: never write OMP's hide-thinking field.
vis.setCalmPresentation(false);
const nativeOn = new Agent.AssistantMessageComponent(true);
const nativeOnWrites = trackWrites(nativeOn);
nativeOn.updateContent(message);
nativeOn.updateContent({
  ...message,
  content: [...message.content, { type: "text", text: "another line" }],
});
nativeOn.invalidate();
if (nativeOnWrites() !== 0) {
  throw new Error("Calm off must not write OMP's hide-thinking field");
}
if (nativeOn.hideThinkingBlock !== true || showsThinking(nativeOn)) {
  throw new Error("Calm off must keep OMP's native hidden thinking hidden");
}
const nativeOff = new Agent.AssistantMessageComponent(false);
const nativeOffWrites = trackWrites(nativeOff);
nativeOff.updateContent(message);
if (nativeOffWrites() !== 0) {
  throw new Error("Calm off must not write OMP's hide-thinking field");
}
if (nativeOff.hideThinkingBlock !== false || !showsThinking(nativeOff)) {
  throw new Error("Calm off must leave OMP's native visible thinking visible");
}

// Calm on collapses thinking by filtering the presentation, still never writing the field.
vis.setCalmPresentation(true);
const calmOn = new Agent.AssistantMessageComponent(false);
const calmOnWrites = trackWrites(calmOn);
calmOn.updateContent(message);
if (calmOnWrites() !== 0) {
  throw new Error("Calm on must not write OMP's hide-thinking field");
}
if (showsThinking(calmOn)) {
  throw new Error("Calm on must not render thinking");
}
thinking.applyOmpCalmThinkingToRememberedRows();
if (showsThinking(calmOn)) {
  throw new Error("Calm on re-apply must not render thinking");
}

// OMP toggles the field itself while Calm is on; Calm off must leave that value standing.
const ompHidden = new Agent.AssistantMessageComponent(false);
ompHidden.updateContent(message);
ompHidden.setHideThinkingBlock(true);
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if (ompHidden.hideThinkingBlock !== true || showsThinking(ompHidden)) {
  throw new Error("Calm off must leave OMP's hidden toggle standing");
}

vis.setCalmPresentation(true);
const ompVisible = new Agent.AssistantMessageComponent(true);
ompVisible.updateContent(message);
ompVisible.setHideThinkingBlock(false);
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if (ompVisible.hideThinkingBlock !== false || !showsThinking(ompVisible)) {
  throw new Error("Calm off must leave OMP's visible toggle standing");
}
JS
)
  status=$?
  expect_code 0 "$status" "native hide-thinking contract: $out"
  [ -z "$out" ] || fail "native hide-thinking contract printed output: $out"
  pass "OMP Calm collapses thinking by filtering only, never writing OMP's native hide-thinking field"
}

test_session_replacement_resets_remembered() {
  local fixture home out status
  fixture="$TMP_ROOT/session-replacement"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home/config"
  printf 'on\n' >"$home/config/calm"
  out=$(cd "$fixture" && FM_HOME="$home" EXT="$fixture/.omp/extensions/fm-calm.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const handlers = new Map();
let calmCommand;
const pi = {
  pi: { Container: class { render() { return []; } } },
  events: { emit() {} },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerMessageRenderer() {},
  registerAssistantThinkingRenderer() {},
};
const mod = await import(`${pathToFileURL(process.env.EXT).href}?replacement=${Date.now()}`);
mod.default(pi);
for (const event of ["session_start", "session_switch", "session_branch", "session_tree"]) {
  if (typeof handlers.get(event) !== "function") {
    throw new Error(`Calm must register the ${event} handler for in-process session replacement`);
  }
}
const ui = {
  notify() {},
  getToolsExpanded() { return false; },
  setToolsExpanded() {},
  setStatus() {},
};
const ctx = { ui };
handlers.get("session_start")({ type: "session_start" }, ctx);

const assistant = new Agent.AssistantMessageComponent(false);
assistant.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "stale note" },
    { type: "toolCall" },
  ],
}, { transient: true });
if ((assistant.rendered || []).some((line) => line === "text:stale note")) {
  throw new Error("Calm-on must hide the working note before the session replacement");
}
handlers.get("session_switch")({ type: "session_switch", reason: "new" }, ctx);
await calmCommand.handler("", ctx);
if ((assistant.rendered || []).some((line) => line === "text:stale note")) {
  throw new Error("session_switch must forget assistant rows remembered before the replacement");
}
JS
)
  status=$?
  expect_code 0 "$status" "session replacement contract: $out"
  [ -z "$out" ] || fail "session replacement contract printed output: $out"
  pass "OMP Calm registers the in-process session replacement events and forgets remembered rows on session_switch"
}

test_calm_off_retry_preserves_options() {
  local fixture out status
  fixture="$TMP_ROOT/off-retry"
  install_omp_calm_fixture "$fixture"
  out=$(cd "$fixture" && node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import * as Agent from "@oh-my-pi/pi-coding-agent";

const thinking = await import(pathToFileURL(`${process.cwd()}/.omp/extensions/lib/fm-calm-assistant-thinking.ts`).href);
const vis = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-visibility-core.ts`).href);
thinking.installOmpCalmAssistantThinking();
vis.setCalmPresentation(true);
const component = new Agent.AssistantMessageComponent(false);
component.updateContent({
  stopReason: "toolUse",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "short note" },
    { type: "toolCall" },
  ],
}, { transient: true });
vis.setCalmPresentation(false);
thinking.applyOmpCalmThinkingToRememberedRows();
if (!(component.rendered || []).some((line) => line === "text:short note")) {
  throw new Error("Calm-off restore must show the working note again");
}
// OMP applyRetryRecovery spreads the restored original the stock component holds.
component.updateContent({ ...component.lastMessage, retryRecovery: { reason: "transport" } });
vis.setCalmPresentation(true);
thinking.applyOmpCalmThinkingToRememberedRows();
if (component.lastOptions?.transient !== true) {
  throw new Error("a retry after Calm-off restore must preserve the remembered transient options");
}
JS
)
  status=$?
  expect_code 0 "$status" "off retry options contract: $out"
  [ -z "$out" ] || fail "off retry options contract printed output: $out"
  pass "a retry after Calm-off restore keeps the remembered transient update options"
}

test_degraded_public_api_seam() {
  local fixture home out status
  fixture="$TMP_ROOT/degraded"
  home="$fixture/home"
  install_omp_calm_fixture "$fixture"
  mkdir -p "$home"
  out=$(cd "$fixture" && FM_HOME="$home" EXT="$fixture/.omp/extensions/fm-calm.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const diagnostics = [];
const original = console.error;
console.error = (...args) => diagnostics.push(args.join(" "));
let calmCommand;
const handlers = new Map();
const pi = {
  pi: {},
  events: { emit() {} },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  // Intentionally omit registerMessageRenderer and registerAssistantThinkingRenderer.
};
let threw = false;
try {
  const mod = await import(`${pathToFileURL(process.env.EXT).href}?deg=${Date.now()}`);
  mod.default(pi);
} catch {
  threw = true;
}
console.error = original;
if (threw) throw new Error("missing public renderer seams must not crash the whole extension");
if (!calmCommand || !handlers.has("session_start")) {
  throw new Error("command and session_start must still register when renderer seams are missing");
}
const sawMessage = diagnostics.some((line) => line.includes("message-renderer") && /unavailable|skip/i.test(line));
const sawThinking = diagnostics.some((line) => line.includes("assistant-thinking-renderer") && /unavailable|skip/i.test(line));
if (!sawMessage || !sawThinking) {
  throw new Error(`missing clear skip diagnostics; saw: ${JSON.stringify(diagnostics)}`);
}
JS
)
  status=$?
  expect_code 0 "$status" "degraded public seams: $out"
  [ -z "$out" ] || fail "degraded public seams printed output: $out"
  pass "missing OMP public renderer seams degrade only those adapters with a clear skip reason"
}

test_preference_read_write_contract
test_calm_command_persists_and_reloads
test_operational_row_hide_show_and_thinking_collapse
test_working_note_via_omp_events
test_double_install_keeps_shared_state
test_retry_recovery_keeps_original_note
test_native_hide_thinking_is_additive
test_session_replacement_resets_remembered
test_calm_off_retry_preserves_options
test_degraded_public_api_seam
