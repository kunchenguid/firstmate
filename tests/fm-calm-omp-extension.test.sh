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
  constructor() {
    this.hideThinkingBlock = false;
    this.lastMessage = undefined;
  }
  setHideThinkingBlock(hide) { this.hideThinkingBlock = hide; }
  invalidate() {
    if (this.lastMessage) this.updateContent(this.lastMessage);
  }
  updateContent(message) {
    this.lastMessage = message;
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
  out=$(cd "$fixture" && PREF="$fixture/.pi/extensions/lib/fm-calm-preference.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync, mkdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
const pref = await import(pathToFileURL(process.env.PREF).href);
const home = resolve("home");
mkdirSync(`${home}/config`, { recursive: true });
const path = pref.calmPreferencePath({ FM_HOME: home }, resolve("."));
if (pref.loadCalmPreference(path) !== false) throw new Error("absent preference must read off");
if (pref.parseCalmPreference(undefined) !== false) throw new Error("undefined must read off");
if (pref.parseCalmPreference("nope\n") !== false) throw new Error("unrecognized must read off");
if (pref.parseCalmPreference("on\n") !== true) throw new Error("on must read on");
if (pref.parseCalmPreference("max\n") !== true) throw new Error("legacy max must read on");
if (pref.serializeCalmPreference(true) !== "on\n") throw new Error("serialize on");
if (pref.serializeCalmPreference(false) !== "off\n") throw new Error("serialize off");
pref.persistCalmPreference(path, true);
if (readFileSync(path, "utf8") !== "on\n") throw new Error("persist did not write on\\n");
const mode = statSync(path).mode & 0o777;
if (mode !== 0o600) throw new Error(`preference mode must be 0600, got ${mode.toString(8)}`);
pref.persistCalmPreference(path, false);
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
});
if (assistant.hideThinkingBlock !== true) {
  throw new Error("Calm-on must collapse thinking via setHideThinkingBlock");
}
if ((assistant.rendered || []).some((line) => line.startsWith("thinking:"))) {
  throw new Error(`Calm-on must not render thinking, got ${JSON.stringify(assistant.rendered)}`);
}
if ((assistant.rendered || []).some((line) => line === "text:short note")) {
  throw new Error(`Calm-on must hide short mid-turn working notes, got ${JSON.stringify(assistant.rendered)}`);
}

await calmCommand.handler("", { ui });
if (opComponent.render(80).length === 0) {
  throw new Error("Calm-off must restore operational rows");
}
if (!(assistant.rendered || []).some((line) => line === "text:short note")) {
  throw new Error(`Calm-off must restore the hidden working note, got ${JSON.stringify(assistant.rendered)}`);
}
assistant.updateContent({
  stopReason: "stop",
  content: [
    { type: "thinking", thinking: "secret plan" },
    { type: "text", text: "final answer for the captain" },
  ],
});
if (assistant.hideThinkingBlock !== false) {
  throw new Error("Calm-off must clear hideThinkingBlock for new assistant rows");
}
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
test_degraded_public_api_seam
