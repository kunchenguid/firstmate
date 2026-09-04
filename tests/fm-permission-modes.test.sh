#!/usr/bin/env bash
# Behavioral tests for the opt-in Pi permission-mode extension
# (.pi/extensions/fm-permission-modes.ts + .pi/extensions/lib/fm-permission-policy.ts).
#
# Covers default-off compatibility, read-only plan calls, blocked mutation,
# confirm allow/deny, noninteractive refusal, malformed command arguments,
# session-persisted state round-trip, and the additive-composition guarantee
# (a no-block decision lets the existing PreToolUse seatbelts run; a block
# short-circuits before them) proven against the real Pi ExtensionRunner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-permission-modes.ts"
POLICY="$ROOT/.pi/extensions/lib/fm-permission-policy.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMP_ROOT=$(fm_test_tmproot fm-permission-modes)
FIXTURE="$TMP_ROOT/fixture"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

build_fixture() {
  mkdir -p \
    "$FIXTURE/lib" \
    "$FIXTURE/node_modules/@earendil-works" \
    "$FIXTURE/node_modules/@types"
  cp "$EXT" "$FIXTURE/fm-permission-modes.ts"
  cp "$POLICY" "$FIXTURE/lib/fm-permission-policy.ts"
  ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$FIXTURE/node_modules/typebox"
  ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$FIXTURE/node_modules/@types/node"
  printf '%s\n' '{"type":"module"}' >"$FIXTURE/package.json"
}

node_guard() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi permission-modes test"
    return 1
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 1
  fi
  return 0
}

run_node() {
  # Run a node --input-type=module heredoc against the fixture. $1 is the heredoc
  # body passed on stdin; the fixture dir is the cwd so relative .ts imports resolve.
  (cd "$FIXTURE" && EXT="$FIXTURE/fm-permission-modes.ts" \
    POLICY="$FIXTURE/lib/fm-permission-policy.ts" \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    node --input-type=module) 2>&1
}

test_pure_policy() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const policy = await import(`${pathToFileURL(process.env.POLICY).href}?pure=${Date.now()}`);

function check(cond, msg) {
  if (!cond) throw new Error(msg);
}

// parsePermissionModeArg: valid modes, missing, unknown, and case sensitivity.
for (const m of ["off", "plan", "confirm"]) {
  const r = policy.parsePermissionModeArg(m);
  check(r.ok && r.mode === m, `parsePermissionModeArg(${m}) failed`);
}
check(!policy.parsePermissionModeArg("").ok, "empty arg parsed as ok");
check(!policy.parsePermissionModeArg("bogus").ok, "unknown arg parsed as ok");
check(!policy.parsePermissionModeArg("PLAN").ok, "uppercase accepted (must be case-sensitive)");
{
  const spaced = policy.parsePermissionModeArg("  plan  ");
  check(spaced.ok && spaced.mode === "plan", "leading/trailing whitespace not trimmed");
}

// classifyToolMutation: built-in tools and neutral custom tools.
check(policy.classifyToolMutation("edit") === "mutate", "edit classified wrong");
check(policy.classifyToolMutation("write") === "mutate", "write classified wrong");
check(policy.classifyToolMutation("bash") === "shell", "bash classified wrong");
check(policy.classifyToolMutation("read") === "read", "read classified wrong");
for (const t of ["ls", "grep", "find"]) {
  check(policy.classifyToolMutation(t) === "read", `${t} classified wrong`);
}
check(policy.classifyToolMutation("custom_thing") === "neutral", "custom tool not neutral");
check(policy.classifyToolMutation("fm_watch_arm_pi") === "neutral", "watcher tool not neutral");

// isReadOnlyShellCommand: genuinely read-only, clearly mutating, chained, and unknown.
for (const ok of ["ls -la", "git status", "git log --oneline", "cat README.md", "head -20 README.md", "tail -20 README.md", "wc -l README.md", "rg TODO .", "grep -r foo .", "find . -name '*.ts'", "echo hello", "node --version", "jq '.x' f.json", "ps aux"]) {
  check(policy.isReadOnlyShellCommand(ok), `read-only command blocked: ${ok}`);
}
for (const bad of ["rm file", "rm -rf /", "git push", "git commit -m x", "echo hi; rm x", "cat f > /etc/passwd", "mkdir d", "chmod 777 .", "sudo ls", "npm install pkg", "vim file", "echo hi > f", "git checkout -b branch", "find . -delete", "find . -exec touch {} +", "find . -execdir touch {} +", "fd -x ./mutator", "rg --pre ./mutator pattern .", "rg --hostname-bin ./mutator pattern .", "git branch new", "git remote add origin x", "git log --output=out", "git diff --ext-diff", "ls; python -c \"open('x','w').write('x')\"", "git status && touch x", "sed -n 'w out' input", "sed -n 'W out' input", "sed -n -i file", "sort input -o output", "sort input -ooutput", "date -s @0", "date -s@0", "awk 'BEGIN { system(\"touch x\") }'", "npm audit --fix"]) {
  check(!policy.isReadOnlyShellCommand(bad), `mutating command allowed: ${bad}`);
}
check(!policy.isReadOnlyShellCommand("totallyUnknownCmd --flag"), "unknown command allowed (must default to non-read-only)");
check(!policy.isReadOnlyShellCommand(""), "empty command classified read-only");
check(!policy.isReadOnlyShellCommand(undefined), "undefined command classified read-only");

// decideToolCall: off allows everything; plan blocks mutation and non-read-only shell;
// confirm prompts for mutation when UI exists and blocks when it does not.
check(policy.decideToolCall("off", "edit", undefined, true).action === "allow", "off blocked edit");
check(policy.decideToolCall("off", "bash", "rm -rf /", true).action === "allow", "off blocked mutating bash");
check(policy.decideToolCall("plan", "edit", undefined, true).action === "block", "plan allowed edit");
check(policy.decideToolCall("plan", "write", undefined, true).action === "block", "plan allowed write");
check(policy.decideToolCall("plan", "read", undefined, true).action === "allow", "plan blocked read");
check(policy.decideToolCall("plan", "bash", "ls", true).action === "allow", "plan blocked read-only bash");
check(policy.decideToolCall("plan", "bash", "rm x", true).action === "block", "plan allowed mutating bash");
check(policy.decideToolCall("plan", "bash", "git status", true).action === "allow", "plan blocked git status");
check(policy.decideToolCall("plan", "custom_thing", undefined, true).action === "allow", "plan gated a neutral custom tool");

const cEditUI = policy.decideToolCall("confirm", "edit", undefined, true);
check(cEditUI.action === "confirm", "confirm did not prompt for edit with UI");
const cEditNoUI = policy.decideToolCall("confirm", "edit", undefined, false);
check(cEditNoUI.action === "block", "confirm did not refuse edit without UI (noninteractive refusal)");
const cBashRO = policy.decideToolCall("confirm", "bash", "ls", true);
check(cBashRO.action === "allow", "confirm prompted for read-only bash");
const cBashMutUI = policy.decideToolCall("confirm", "bash", "rm x", true);
check(cBashMutUI.action === "confirm", "confirm did not prompt for mutating bash");
const cBashMutNoUI = policy.decideToolCall("confirm", "bash", "rm x", false);
check(cBashMutNoUI.action === "block", "confirm allowed mutating bash without UI");
check(policy.decideToolCall("confirm", "read", undefined, false).action === "allow", "confirm refused a read-only tool without UI");

// modeStatusLabel: off clears the footer; plan/confirm label themselves.
check(policy.modeStatusLabel("off") === undefined, "off produced a footer label");
check(policy.modeStatusLabel("plan") === "permission: plan", "plan label wrong");
check(policy.modeStatusLabel("confirm") === "permission: confirm", "confirm label wrong");
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "pure policy checks failed: $out"
  [ -z "$out" ] || fail "pure policy test printed output: $out"
  pass "pure policy: parsing, tool classification, read-only shell, and mode decisions (including noninteractive refusal)"
}

test_default_off_compatibility() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const ext = await import(`${pathToFileURL(process.env.EXT).href}?off=${Date.now()}`);
const handlers = new Map();
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = handlers.get(ev) || []; a.push(h); handlers.set(ev, a); },
  registerCommand() {},
  appendEntry() {},
};
ext.default(pi);
const toolCall = handlers.get("tool_call")[0];
const ctx = {
  hasUI: true,
  ui: { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } },
  sessionManager: { getEntries: () => [] },
};
// Off is the default and must not block any tool, including mutating ones.
for (const [name, input] of [
  ["edit", { path: "f", edits: [] }],
  ["write", { path: "f", content: "x" }],
  ["read", { path: "f" }],
  ["bash", { command: "rm -rf /tmp/anything" }],
  ["bash", { command: "git push" }],
  ["custom_tool", { x: 1 }],
]) {
  const r = await toolCall({ type: "tool_call", toolName: name, toolCallId: name, input }, ctx);
  if (r && r.block) throw new Error(`off mode blocked ${name}: ${JSON.stringify(r)}`);
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "default-off compatibility failed: $out"
  [ -z "$out" ] || fail "default-off test printed output: $out"
  pass "off mode preserves behavior: edit, write, read, mutating bash, and custom tools all pass unblocked"
}

test_plan_readonly_allowed_and_mutation_blocked() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const ext = await import(`${pathToFileURL(process.env.EXT).href}?plan=${Date.now()}`);
const handlers = new Map();
const commands = {};
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = handlers.get(ev) || []; a.push(h); handlers.set(ev, a); },
  registerCommand(name, opts) { commands[name] = opts; },
  appendEntry() {},
};
ext.default(pi);
const ctx = {
  hasUI: true,
  ui: { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } },
  sessionManager: { getEntries: () => [] },
};
await commands["fm-permissions"].handler("plan", ctx);
const toolCall = handlers.get("tool_call")[0];
async function expectAllow(name, input, label) {
  const r = await toolCall({ type: "tool_call", toolName: name, toolCallId: label, input }, ctx);
  if (r && r.block) throw new Error(`plan blocked a read-only call ${label}: ${JSON.stringify(r)}`);
}
async function expectBlock(name, input, label) {
  const r = await toolCall({ type: "tool_call", toolName: name, toolCallId: label, input }, ctx);
  if (!r || !r.block) throw new Error(`plan allowed a mutation ${label}: ${JSON.stringify(r)}`);
}
// Genuinely read-only inspection is allowed.
await expectAllow("read", { path: "f" }, "read");
await expectAllow("ls", { path: "." }, "ls");
await expectAllow("grep", { pattern: "x", path: "." }, "grep");
await expectAllow("bash", { command: "git status" }, "git-status");
await expectAllow("bash", { command: "cat README.md" }, "cat");
await expectAllow("bash", { command: "rg TODO ." }, "rg");
// Mutations are blocked, including chained and redirected ones.
await expectBlock("edit", { path: "f", edits: [] }, "edit");
await expectBlock("write", { path: "f", content: "x" }, "write");
await expectBlock("bash", { command: "rm file" }, "rm");
await expectBlock("bash", { command: "git push" }, "git-push");
await expectBlock("bash", { command: "echo hi; rm x" }, "chained-rm");
await expectBlock("bash", { command: "cat f > /etc/passwd" }, "redirect");
await expectBlock("bash", { command: "npm install pkg" }, "npm-install");
await expectBlock("bash", { command: "sed -n 'w out' input" }, "sed-write");
await expectBlock("bash", { command: "fd -x ./mutator" }, "fd-exec");
await expectBlock("bash", { command: "sort input -ooutput" }, "sort-output");
await expectBlock("bash", { command: "date -s@0" }, "date-set");
await expectBlock("bash", { command: "awk 'BEGIN { system(\"touch x\") }'" }, "awk-system");
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "plan mode checks failed: $out"
  [ -z "$out" ] || fail "plan mode test printed output: $out"
  pass "plan mode allows read-only inspection (read, ls, grep, git status, cat, rg) and blocks edit, write, and mutating/chained/redirected bash"
}

test_confirm_allow_deny_and_noninteractive_refusal() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const ext = await import(`${pathToFileURL(process.env.EXT).href}?confirm=${Date.now()}`);
const handlers = new Map();
const commands = {};
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = handlers.get(ev) || []; a.push(h); handlers.set(ev, a); },
  registerCommand(name, opts) { commands[name] = opts; },
  appendEntry() {},
};
ext.default(pi);
let nextConfirm = false;
let confirmCalls = 0;
const ctxInteractive = {
  hasUI: true,
  ui: {
    notify() {},
    setStatus() {},
    confirm: async () => { confirmCalls += 1; return nextConfirm; },
    theme: { fg: (_c, t) => t },
  },
  sessionManager: { getEntries: () => [] },
};
const ctxHeadless = { hasUI: false, ui: { notify() {}, setStatus() {}, confirm: async () => { throw new Error("confirm must not be called headless"); }, theme: { fg: (_c, t) => t } }, sessionManager: { getEntries: () => [] } };
await commands["fm-permissions"].handler("confirm", ctxInteractive);
const toolCall = handlers.get("tool_call")[0];

// Allow path: user approves a mutating tool.
nextConfirm = true; confirmCalls = 0;
let r = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e1", input: { path: "f", edits: [] } }, ctxInteractive);
if (r && r.block) throw new Error(`confirm denied edit despite approval: ${JSON.stringify(r)}`);
if (confirmCalls !== 1) throw new Error(`confirm called ${confirmCalls}x for edit (expected 1)`);

// Deny path: user rejects a mutating tool.
nextConfirm = false; confirmCalls = 0;
r = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e2", input: { path: "f", edits: [] } }, ctxInteractive);
if (!r || !r.block) throw new Error(`confirm allowed edit despite denial: ${JSON.stringify(r)}`);
if (confirmCalls !== 1) throw new Error(`confirm called ${confirmCalls}x for denied edit (expected 1)`);

// Mutating bash prompts and respects the answer.
nextConfirm = true; confirmCalls = 0;
r = await toolCall({ type: "tool_call", toolName: "bash", toolCallId: "b1", input: { command: "rm x" } }, ctxInteractive);
if (r && r.block) throw new Error(`confirm denied mutating bash despite approval: ${JSON.stringify(r)}`);
if (confirmCalls !== 1) throw new Error(`confirm called ${confirmCalls}x for mutating bash (expected 1)`);

// Read-only bash is not prompted.
nextConfirm = false; confirmCalls = 0;
r = await toolCall({ type: "tool_call", toolName: "bash", toolCallId: "b2", input: { command: "ls" } }, ctxInteractive);
if (r && r.block) throw new Error(`confirm blocked read-only bash: ${JSON.stringify(r)}`);
if (confirmCalls !== 0) throw new Error(`confirm prompted for read-only bash ${confirmCalls}x`);

// Noninteractive refusal: no UI must block a mutating call rather than permit it.
r = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e3", input: { path: "f", edits: [] } }, ctxHeadless);
if (!r || !r.block) throw new Error(`headless confirm allowed edit (must refuse): ${JSON.stringify(r)}`);
r = await toolCall({ type: "tool_call", toolName: "bash", toolCallId: "b3", input: { command: "rm x" } }, ctxHeadless);
if (!r || !r.block) throw new Error(`headless confirm allowed mutating bash (must refuse): ${JSON.stringify(r)}`);
// Read-only tools still pass headless.
r = await toolCall({ type: "tool_call", toolName: "read", toolCallId: "r1", input: { path: "f" } }, ctxHeadless);
if (r && r.block) throw new Error(`headless confirm blocked read: ${JSON.stringify(r)}`);
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "confirm allow/deny/refusal checks failed: $out"
  [ -z "$out" ] || fail "confirm test printed output: $out"
  pass "confirm mode prompts mutating tools (allow/deny), skips read-only bash, and refuses mutating calls without a UI"
}

test_malformed_command_arguments() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const ext = await import(`${pathToFileURL(process.env.EXT).href}?cmd=${Date.now()}`);
const handlers = new Map();
const commands = {};
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = handlers.get(ev) || []; a.push(h); handlers.set(ev, a); },
  registerCommand(name, opts) { commands[name] = opts; },
  appendEntry() {},
};
ext.default(pi);
const notifications = [];
const ctx = {
  hasUI: true,
  ui: { notify: (m, t) => notifications.push({ m, t }), setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } },
  sessionManager: { getEntries: () => [] },
};
const toolCall = handlers.get("tool_call")[0];
const cmd = commands["fm-permissions"];

// Empty invocation is a status query, not an error; mode stays off and nothing is blocked.
notifications.length = 0;
await cmd.handler("", ctx);
if (notifications.length !== 1 || notifications[0].t !== "info") throw new Error(`empty invocation did not notify status: ${JSON.stringify(notifications)}`);
if (!notifications[0].m.includes("off")) throw new Error(`status did not report off: ${notifications[0].m}`);
const r = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e", input: { path: "f", edits: [] } }, ctx);
if (r && r.block) throw new Error(`status query changed mode and blocked edit: ${JSON.stringify(r)}`);

// Malformed argument notifies an error and leaves the mode unchanged.
notifications.length = 0;
await cmd.handler("bogus", ctx);
if (notifications.length !== 1 || notifications[0].t !== "error") throw new Error(`bogus arg did not notify error: ${JSON.stringify(notifications)}`);
if (!/usage|unknown mode/i.test(notifications[0].m)) throw new Error(`error message did not guide usage: ${notifications[0].m}`);
const r2 = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e2", input: { path: "f", edits: [] } }, ctx);
if (r2 && r2.block) throw new Error(`bogus arg changed mode to a blocking one: ${JSON.stringify(r2)}`);

// Case sensitivity: PLAN is not accepted.
notifications.length = 0;
await cmd.handler("PLAN", ctx);
if (notifications[0].t !== "error") throw new Error(`uppercase PLAN accepted: ${JSON.stringify(notifications)}`);
const r3 = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e3", input: { path: "f", edits: [] } }, ctx);
if (r3 && r3.block) throw new Error(`uppercase PLAN changed mode: ${JSON.stringify(r3)}`);

// Valid modes round-trip and take effect.
await cmd.handler("plan", ctx);
const r4 = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e4", input: { path: "f", edits: [] } }, ctx);
if (!r4 || !r4.block) throw new Error(`plan did not take effect after valid arg: ${JSON.stringify(r4)}`);
await cmd.handler("off", ctx);
const r5 = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e5", input: { path: "f", edits: [] } }, ctx);
if (r5 && r5.block) throw new Error(`off did not restore behavior after valid arg: ${JSON.stringify(r5)}`);

// Trailing whitespace is trimmed and accepted.
await cmd.handler("  plan  ", ctx);
const r6 = await toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e6", input: { path: "f", edits: [] } }, ctx);
if (!r6 || !r6.block) throw new Error(`trailing-whitespace plan did not take effect: ${JSON.stringify(r6)}`);
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed command argument checks failed: $out"
  [ -z "$out" ] || fail "malformed command test printed output: $out"
  pass "command handles empty (status), malformed (error, mode unchanged), case sensitivity, trailing whitespace, and valid round-trips"
}

test_session_persisted_state_roundtrip() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const ext = await import(`${pathToFileURL(process.env.EXT).href}?persist=${Date.now()}`);
const handlers = new Map();
const commands = {};
const appended = [];
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = handlers.get(ev) || []; a.push(h); handlers.set(ev, a); },
  registerCommand(name, opts) { commands[name] = opts; },
  appendEntry(customType, data) { appended.push({ customType, data }); },
};
ext.default(pi);
const ctx = {
  hasUI: true,
  ui: { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } },
  sessionManager: { getEntries: () => [] },
};
await commands["fm-permissions"].handler("plan", ctx);
if (appended.length !== 1 || appended[0].customType !== "fm-permission-modes" || appended[0].data?.mode !== "plan") {
  throw new Error(`appendEntry did not persist plan mode: ${JSON.stringify(appended)}`);
}
await commands["fm-permissions"].handler("confirm", ctx);
if (appended[appended.length - 1].data?.mode !== "confirm") {
  throw new Error(`appendEntry did not persist confirm mode: ${JSON.stringify(appended)}`);
}

const sessionStart = handlers.get("session_start")[0];
const toolCall = handlers.get("tool_call")[0];
const mkCtx = (entries) => ({
  hasUI: true,
  ui: { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } },
  sessionManager: { getEntries: () => entries },
});
const fireEdit = async (ctx) => toolCall({ type: "tool_call", toolName: "edit", toolCallId: "e", input: { path: "f", edits: [] } }, ctx);

// Reset to off first, so the restore below is what sets the mode.
await commands["fm-permissions"].handler("off", ctx);

// session_start restores the last valid persisted mode (confirm) from Pi session entries.
// Confirm mode is proven by noninteractive refusal: a headless mutating call must be
// refused, proving the mode was restored from entries rather than left at off.
const restoredCtx = mkCtx([
  { type: "custom", customType: "fm-permission-modes", data: { mode: "plan" } },
  { type: "custom", customType: "fm-permission-modes", data: { mode: "confirm" } },
]);
await sessionStart({ type: "session_start", reason: "resume" }, restoredCtx);
{
  const headless = { ...restoredCtx, hasUI: false };
  const r = await fireEdit(headless);
  if (!r || !r.block) throw new Error(`session_start did not restore confirm mode (headless edit not refused): ${JSON.stringify(r)}`);
}

// Malformed persisted mode is ignored, leaving the mode at off after a reset.
const freshCtx = mkCtx([{ type: "custom", customType: "fm-permission-modes", data: { mode: "bogus" } }]);
await sessionStart({ type: "session_start", reason: "startup" }, freshCtx);
{
  const headless = { ...freshCtx, hasUI: false };
  const r = await fireEdit(headless);
  if (r && r.block) throw new Error(`malformed persisted mode restored a blocking mode: ${JSON.stringify(r)}`);
}

// A fresh session with no entries resets a previously restored mode to off.
await sessionStart({ type: "session_start", reason: "resume" }, restoredCtx);
const emptyCtx = mkCtx([]);
await sessionStart({ type: "session_start", reason: "new" }, emptyCtx);
{
  const headless = { ...emptyCtx, hasUI: false };
  const r = await fireEdit(headless);
  if (r && r.block) throw new Error(`fresh session did not start off: ${JSON.stringify(r)}`);
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "session-persisted state round-trip failed: $out"
  [ -z "$out" ] || fail "persistence test printed output: $out"
  pass "mode state persists via appendEntry, restores on session_start (last valid entry), ignores malformed entries, and defaults to off on a fresh session"
}

test_additive_composition_with_real_runner() {
  local out status
  node_guard || return 0
  out=$(run_node <<'JS'
import { pathToFileURL } from "node:url";
const packageRoot = process.env.PI_PACKAGE_DIR;
const { ExtensionRunner } = await import(pathToFileURL(`${packageRoot}/dist/core/extensions/runner.js`).href);

// Load the real permission-mode extension to register its real tool_call handler.
const ext = await import(`${pathToFileURL(process.env.EXT).href}?compose=${Date.now()}`);
const myHandlers = new Map();
const commands = {};
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { const a = myHandlers.get(ev) || []; a.push(h); myHandlers.set(ev, a); },
  registerCommand(name, opts) { commands[name] = opts; },
  appendEntry() {},
};
ext.default(pi);

// A second "seatbelt" handler stands in for the existing turn-end guard
// PreToolUse checks. It records that it ran and never blocks on its own.
let seatbeltRan = false;
const seatbelt = async (_event, _ctx) => { seatbeltRan = true; return {}; };

// Build two fake Extension objects the way the Pi loader does: a handlers Map.
const mine = { handlers: myHandlers };
const seat = { handlers: new Map([["tool_call", [seatbelt]]]) };
const runtime = {
  flagValues: new Map(),
  pendingProviderRegistrations: [],
  pendingNativeProviderRegistrations: [],
  invalidate() {},
  assertActive() {},
  trackEventBusSubscription(fn) { return fn; },
  getThinkingLevel: () => "off",
  registerProvider() {},
  registerNativeProvider() {},
  unregisterProvider() {},
};
const runner = new ExtensionRunner([mine, seat], runtime, process.cwd(), { getEntries: () => [] }, { registerProvider() {} });
runner.uiContext = { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } };

async function fire(toolName, input) {
  seatbeltRan = false;
  const result = await runner.emitToolCall({ type: "tool_call", toolName, toolCallId: toolName, input });
  return { result, seatbeltRan };
}

// Off (default): a no-block decision must let the seatbelt run (additive, no weakening).
let obs = await fire("edit", { path: "f", edits: [] });
if (obs.result && obs.result.block) throw new Error(`off blocked edit: ${JSON.stringify(obs.result)}`);
if (!obs.seatbeltRan) throw new Error("off short-circuited the seatbelt (weakened the existing gate)");

// Plan mode, edit: a block short-circuits, so the seatbelt never runs.
await commands["fm-permissions"].handler("plan", { ui: runner.uiContext, hasUI: true, sessionManager: { getEntries: () => [] } });
obs = await fire("edit", { path: "f", edits: [] });
if (!obs.result || !obs.result.block) throw new Error(`plan did not block edit: ${JSON.stringify(obs.result)}`);
if (obs.seatbeltRan) throw new Error("plan block let the seatbelt run anyway (should short-circuit)");

// Plan mode, read-only bash: a no-block decision lets the seatbelt run.
obs = await fire("bash", { command: "ls -la" });
if (obs.result && obs.result.block) throw new Error(`plan blocked read-only bash: ${JSON.stringify(obs.result)}`);
if (!obs.seatbeltRan) throw new Error("plan read-only bash short-circuited the seatbelt");

// Confirm mode, approved mutating call: the no-block decision lets the seatbelt
// run, proving approval never bypasses the existing PreToolUse seatbelts.
await commands["fm-permissions"].handler("confirm", { ui: runner.uiContext, hasUI: true, sessionManager: { getEntries: () => [] } });
runner.uiContext = { notify() {}, setStatus() {}, confirm: async () => true, theme: { fg: (_c, t) => t } };
obs = await fire("edit", { path: "f", edits: [] });
if (obs.result && obs.result.block) throw new Error(`confirm denied approved edit: ${JSON.stringify(obs.result)}`);
if (!obs.seatbeltRan) throw new Error("confirm approval bypassed the seatbelt (weakened the existing gate)");

// Confirm mode, denied mutating call: a block short-circuits before the seatbelt.
runner.uiContext = { notify() {}, setStatus() {}, confirm: async () => false, theme: { fg: (_c, t) => t } };
obs = await fire("edit", { path: "f", edits: [] });
if (!obs.result || !obs.result.block) throw new Error(`confirm allowed denied edit: ${JSON.stringify(obs.result)}`);
if (obs.seatbeltRan) throw new Error("confirm denial let the seatbelt run anyway (should short-circuit)");
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "additive composition proof failed: $out"
  [ -z "$out" ] || fail "composition test printed output: $out"
  pass "additive composition (real Pi runner): off and approved calls let the seatbelt run; plan and denied calls short-circuit before it - permission modes never weaken the existing seatbelts"
}

build_fixture

test_pure_policy
test_default_off_compatibility
test_plan_readonly_allowed_and_mutation_blocked
test_confirm_allow_deny_and_noninteractive_refusal
test_malformed_command_arguments
test_session_persisted_state_roundtrip
test_additive_composition_with_real_runner
