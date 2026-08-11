#!/usr/bin/env bash
# Focused rendering, quota-data, staleness, narrow-width, and lifecycle
# checks for the fm-quota-statusline Pi extension.
#
# The node harness below imports the tracked extension and its pure data and
# render modules, drives them through their public interface (the parsed
# quota-axi JSON shape, the live Pi session values, and the footer component's
# render(width) method), and asserts the visible output. It never asserts
# implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-statusline)
EXT="$ROOT/.pi/extensions/fm-quota-statusline.ts"
DATA="$ROOT/.pi/extensions/lib/fm-quota-statusline-data.ts"
RENDER="$ROOT/.pi/extensions/lib/fm-quota-statusline-render.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node not found for statusline renderer test"
  exit 0
fi
fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture/node_modules/@earendil-works" "$fixture/lib"
if [ -f "$PI_PACKAGE_DIR/package.json" ]; then
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
else
  mkdir -p "$fixture/node_modules/@earendil-works/pi-tui"
  printf '%s\n' '{"type":"module","exports":"./index.js"}' >"$fixture/node_modules/@earendil-works/pi-tui/package.json"
  cat >"$fixture/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export function visibleWidth(text) {
  return [...text.replace(/\x1b\[[0-9;]*m/g, "")].length;
}
export function truncateToWidth(text, width) {
  if (width <= 0) return "";
  let output = "";
  let visible = 0;
  for (let index = 0; index < text.length && visible < width;) {
    const ansi = text.slice(index).match(/^\x1b\[[0-9;]*m/);
    if (ansi) {
      output += ansi[0];
      index += ansi[0].length;
      continue;
    }
    const point = String.fromCodePoint(text.codePointAt(index));
    output += point;
    index += point.length;
    visible += 1;
  }
  return output;
}
JS
fi
printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
cp "$EXT" "$fixture/fm-quota-statusline.ts"
cp "$DATA" "$fixture/lib/fm-quota-statusline-data.ts"
cp "$RENDER" "$fixture/lib/fm-quota-statusline-render.ts"

output_file="$fixture/node-output"
( cd "$fixture" && node --input-type=module ) >"$output_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { visibleWidth } from "@earendil-works/pi-tui";
import { parseQuotaJson, extractWindows, getProviderQuotaStatus } from "./lib/fm-quota-statusline-data.ts";
import { renderFooter } from "./lib/fm-quota-statusline-render.ts";

const results = [];
const check = (name, cond) => {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? "ok -" : "not ok -"} ${name}`);
};

// --- Fresh quota rendering ----------------------------------------------
// A representative schemaVersion-3 document with one weekly window.
const freshJson = JSON.stringify({
  generatedAt: "2026-08-11T06:49:19.223Z",
  schemaVersion: 3,
  providers: [{
    provider: "codex",
    label: "Codex",
    windows: [{
      id: "weekly",
      label: "week",
      percentUsed: 5,
      percentRemaining: 95,
      resetsAt: "2026-08-18T03:30:39.000Z",
      windowSeconds: 604800,
    }],
    state: { status: "fresh", stale: false },
  }],
});
const freshState = parseQuotaJson(freshJson);
check("parses a fresh quota document", freshState !== null);
const freshWindows = extractWindows(freshState, "codex");
check("extracts the weekly window", freshWindows.length === 1 && freshWindows[0].id === "weekly");
check("classifies provider-declared fresh data", getProviderQuotaStatus(freshState, "codex") === "fresh");

const staleState = parseQuotaJson(JSON.stringify({
  providers: [{
    provider: "codex",
    windows: [{ id: "weekly", label: "week", percentRemaining: 82 }],
    state: { status: "stale", stale: true },
  }],
}));
const noStateState = parseQuotaJson(JSON.stringify({
  providers: [{
    provider: "codex",
    windows: [{ id: "weekly", label: "week", percentRemaining: 82 }],
  }],
}));
check("preserves provider-declared stale data", getProviderQuotaStatus(staleState, "codex") === "stale");
check("does not assume missing freshness metadata is fresh", getProviderQuotaStatus(noStateState, "codex") === "stale");

const theme = { fg: (_color, text) => text };
const now = Date.parse("2026-08-11T07:00:00.000Z");
const freshInput = {
  repoPath: "~/Developer/firstmate",
  branch: "main",
  contextPercent: 70.1,
  contextTokens: 272000,
  modelId: "gpt-5.6-terra",
  thinkingLevel: "high",
  windows: freshWindows,
  quotaStatus: "fresh",
  now,
};
const freshLines = renderFooter(freshInput, theme, 120);
check("fresh footer has two lines", freshLines.length === 2);
check("line 1 shows repo path and branch", /~\/Developer\/firstmate \(main\)/.test(freshLines[0] ?? ""));
const freshLine2 = freshLines[1] ?? "";
check("line 2 shows context percent", freshLine2.includes("70.1%"));
check("line 2 shows context tokens", freshLine2.includes("272.0k"));
check("line 2 shows the weekly window label", freshLine2.includes("week: 95%"));
check("line 2 shows reset countdown", freshLine2.includes("6d"));
check("line 2 shows model and thinking level", freshLine2.includes("gpt-5.6-terra") && freshLine2.includes("high"));
// Only verified windows appear: a fabricated short window must never render.
check("fresh footer never invents a 5h window", !freshLine2.includes("5h:"));

// --- Absent / unavailable quota -----------------------------------------
// Empty providers array parses to null so the footer shows unavailable.
const emptyState = parseQuotaJson('{"providers":[]}');
check("empty providers document is null", emptyState === null);
const unavailableLines = renderFooter(
  { ...freshInput, windows: [], quotaStatus: "unavailable" },
  theme,
  120,
);
const unavailableLine2 = unavailableLines[1] ?? "";
check("unavailable footer shows n/a marker", unavailableLine2.includes("quota: n/a"));
check("unavailable footer shows no fabricated percentage", !/\d+%.*quota|quota.*\d+%/.test(unavailableLine2.replace("quota: n/a", "")));

// --- Stale last-good data -----------------------------------------------
// On a transient failure the last known good windows are retained and the
// segment is marked stale so the captain can see the data may be behind.
const staleLines = renderFooter(
  { ...freshInput, windows: freshWindows, quotaStatus: "stale" },
  theme,
  120,
);
const staleLine2 = staleLines[1] ?? "";
check("stale footer preserves the last-good weekly window", staleLine2.includes("week: 95%"));
check("stale footer marks the data stale", staleLine2.includes("quota~"));

// --- Narrow width behavior ---------------------------------------------
// Narrow layouts use continuation lines without overflowing the terminal.
const narrowLines = renderFooter(freshInput, theme, 18);
const narrowJoined = narrowLines.join("");
check("narrow footer uses continuation lines", narrowLines.length > 1);
check("narrow footer stays within the width", narrowLines.every((line) => visibleWidth(line) <= 18));
check("narrow footer preserves repo and branch", narrowJoined.includes("~/Developer/firstmate") && narrowJoined.includes("main"));
check("narrow footer preserves context", narrowJoined.includes("70.1%") && narrowJoined.includes("272.0k"));
check("narrow footer preserves quota", narrowJoined.includes("week: 95%") && narrowJoined.includes("6d"));
check("narrow footer preserves model and thinking", narrowJoined.includes("gpt-5.6-terra") && narrowJoined.includes("high"));
// Even narrower: truncation must be ANSI-safe and not throw.
const tinyLines = renderFooter(freshInput, theme, 6);
check("tiny width does not throw and yields lines", tinyLines.length > 0);
check("tiny footer stays within the requested width", tinyLines.every((line) => visibleWidth(line) <= 6));
const zeroLines = renderFooter(freshInput, theme, 0);
check("zero-width footer is empty", (zeroLines[0] ?? "").length === 0);

const multiWindowInput = {
  ...freshInput,
  windows: [
    { id: "primary", label: "5h", percentRemaining: 73, resetsAt: "2026-08-11T12:00:00.000Z" },
    { id: "weekly", label: "week", percentRemaining: 86, resetsAt: "2026-08-18T03:30:39.000Z" },
    { id: "review", label: "code-review", percentRemaining: 64, resetsAt: "2026-08-13T07:00:00.000Z" },
    { id: "model", label: "gpt-5.6", percentRemaining: 51, resetsAt: "2026-08-12T07:00:00.000Z" },
  ],
};
const multiWindowLines = renderFooter(multiWindowInput, theme, 48);
const multiWindowText = multiWindowLines.join("\n");
check("multi-window footer stays within width", multiWindowLines.every((line) => visibleWidth(line) <= 48));
check("multi-window footer preserves every label", ["5h: 73%", "week: 86%", "code-review: 64%", "gpt-5.6: 51%"].every((value) => multiWindowText.includes(value)));
check("multi-window footer preserves every reset", ["(5h)", "(6d)", "(2d)", "(1d)"].every((value) => multiWindowText.includes(value)));

// --- Defensive parsing --------------------------------------------------
// A non-JSON string and a structurally empty document both resolve to null
// rather than crashing the footer.
check("malformed JSON is null", parseQuotaJson("not json") === null);
check("non-object JSON is null", parseQuotaJson('"hello"') === null);
const noWindowsState = parseQuotaJson('{"providers":[{"provider":"codex","windows":[]}]}');
check("provider with no usable windows extracts none", extractWindows(noWindowsState, "codex").length === 0);

// --- Lifecycle via the extension ----------------------------------------
// Exercise the tracked extension through a fake ExtensionAPI so the public
// command and footer factory behave correctly without booting the TUI.
const mod = await import(pathToFileURL("./fm-quota-statusline.ts").href);
const eventHandlers = new Map();
let footerFactory = "STOCK";
let notifyMessages = [];
let statusCmd = null;
let execResult = { stdout: freshJson, stderr: "", code: 0, killed: false };
let execCalls = 0;
const fakeCtx = () => ({
  cwd: "/Users/ediz/Developer/firstmate",
  model: { id: "gpt-5.6-terra" },
  thinkingLevel: "high",
  getContextUsage: () => ({ tokens: 272000, contextWindow: 200000, percent: 70.1 }),
  ui: {
    setFooter: (f) => { footerFactory = f; },
    notify: (message, type) => { notifyMessages.push({ message, type }); },
  },
});
const fakePi = {
  exec: async () => {
    execCalls += 1;
    return execResult;
  },
  getThinkingLevel: () => "high",
  on: (event, handler) => {
    const list = eventHandlers.get(event) ?? [];
    list.push(handler);
    eventHandlers.set(event, list);
  },
  registerCommand: (_name, options) => { statusCmd = options; },
};
mod.default(fakePi);
check("extension registers the /statusline command", statusCmd !== null);

// Enable: installs a footer factory and refreshes quota.
await statusCmd.handler("", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
check("enable installs a footer factory", typeof footerFactory === "function");
check("enable notifies the captain", notifyMessages.some((n) => /enabled/i.test(n.message)));
check("enable refreshes quota once", execCalls === 1);

const enabledFooterFactory = footerFactory;
notifyMessages = [];
await statusCmd.handler("on", fakeCtx());
check("on is idempotent while enabled", footerFactory === enabledFooterFactory);
check("idempotent on does not restore stock", !notifyMessages.some((n) => /stock/i.test(n.message)));

for (const handler of (eventHandlers.get("thinking_level_select") ?? [])) {
  handler({}, fakeCtx());
}
await new Promise((resolve) => setTimeout(resolve, 50));
check("thinking-level changes refresh quota", execCalls === 2);

// Render through the installed component to confirm it produces the footer.
const component = footerFactory(
  { requestRender() {} },
  { fg: (_c, t) => t },
  { getGitBranch: () => "main", onBranchChange: () => () => {} },
);
const componentLines = component.render(120);
check("installed footer renders two lines", componentLines.length === 2);
check("installed footer line 1 shows branch", (componentLines[0] ?? "").includes("(main)"));

execResult = { stdout: JSON.stringify({
  providers: [{
    provider: "codex",
    windows: [{ id: "weekly", label: "week", percentRemaining: 82 }],
    state: { status: "stale", stale: true },
  }],
}), stderr: "", code: 0, killed: false };
await statusCmd.handler("refresh", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
const staleComponentLines = component.render(120);
const staleComponentLine2 = staleComponentLines[1] ?? "";
check("provider-stale refresh uses reported windows", staleComponentLine2.includes("week: 82%"));
check("provider-stale refresh is marked stale", staleComponentLine2.includes("quota~"));

execResult = { stdout: freshJson, stderr: "boom", code: 1, killed: false };
await statusCmd.handler("refresh", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
const failedRefreshLine2 = component.render(120)[1] ?? "";
check("nonzero refresh does not accept stdout as fresh", failedRefreshLine2.includes("quota~") && failedRefreshLine2.includes("week: 82%"));

// Restore stock footer.
notifyMessages = [];
await statusCmd.handler("off", fakeCtx());
check("off restores the stock footer (undefined)", footerFactory === undefined);
check("off notifies the captain", notifyMessages.some((n) => /stock/i.test(n.message)));

const callsBeforeInactiveRefresh = execCalls;
execResult = { stdout: freshJson, stderr: "", code: 0, killed: false };
await statusCmd.handler("refresh", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
check("inactive refresh fetches quota", execCalls === callsBeforeInactiveRefresh + 1);
check("inactive refresh does not enable the footer", footerFactory === undefined);

await statusCmd.handler("on", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
const onFooterFactory = footerFactory;
await statusCmd.handler("on", fakeCtx());
check("repeated on keeps the custom footer installed", footerFactory === onFooterFactory);
await statusCmd.handler("", fakeCtx());
check("bare statusline toggles an enabled footer off", footerFactory === undefined);

// Fire session_shutdown to clear the periodic timer so the harness exits.
for (const handler of (eventHandlers.get("session_shutdown") ?? [])) {
  handler({}, fakeCtx());
}

const lifecycleHandlers = new Map();
let lifecycleCommand = null;
let lifecycleFooterFactory = undefined;
let lifecycleCalls = 0;
let activeExecs = 0;
let maxActiveExecs = 0;
const execResolvers = [];
const lifecycleCtx = () => ({
  cwd: "/tmp/new-session",
  model: { id: "gpt-5.6-terra" },
  thinkingLevel: "high",
  getContextUsage: () => ({ tokens: 10, contextWindow: 100, percent: 10 }),
  ui: {
    setFooter: (factory) => { lifecycleFooterFactory = factory; },
    notify: () => {},
  },
});
mod.default({
  exec: () => new Promise((resolve) => {
    lifecycleCalls += 1;
    activeExecs += 1;
    maxActiveExecs = Math.max(maxActiveExecs, activeExecs);
    execResolvers.push((result) => {
      activeExecs -= 1;
      resolve(result);
    });
  }),
  getThinkingLevel: () => "high",
  on: (event, handler) => {
    const list = lifecycleHandlers.get(event) ?? [];
    list.push(handler);
    lifecycleHandlers.set(event, list);
  },
  registerCommand: (_name, options) => { lifecycleCommand = options; },
});
await lifecycleCommand.handler("on", lifecycleCtx());
for (const handler of (lifecycleHandlers.get("session_shutdown") ?? [])) {
  handler({}, lifecycleCtx());
}
for (const handler of (lifecycleHandlers.get("session_start") ?? [])) {
  handler({}, lifecycleCtx());
}
check("session restart does not overlap an in-flight refresh", lifecycleCalls === 1 && maxActiveExecs === 1);
execResolvers.shift()({ stdout: JSON.stringify({
  providers: [{
    provider: "codex",
    windows: [{ id: "weekly", label: "week", percentRemaining: 11 }],
    state: { status: "fresh", stale: false },
  }],
}), stderr: "", code: 0, killed: false });
await new Promise((resolve) => setTimeout(resolve, 50));
check("session restart queues a replacement refresh", lifecycleCalls === 2 && maxActiveExecs === 1);
execResolvers.shift()({ stdout: JSON.stringify({
  providers: [{
    provider: "codex",
    windows: [{ id: "weekly", label: "week", percentRemaining: 77 }],
    state: { status: "fresh", stale: false },
  }],
}), stderr: "", code: 0, killed: false });
await new Promise((resolve) => setTimeout(resolve, 50));
const lifecycleComponent = lifecycleFooterFactory(
  { requestRender() {} },
  { fg: (_c, t) => t },
  { getGitBranch: () => "main", onBranchChange: () => () => {} },
);
const lifecycleLine2 = lifecycleComponent.render(120)[1] ?? "";
check("pre-shutdown refresh cannot overwrite the new session", lifecycleLine2.includes("week: 77%") && !lifecycleLine2.includes("week: 11%"));
for (const handler of (lifecycleHandlers.get("session_shutdown") ?? [])) {
  handler({}, lifecycleCtx());
}

const failed = results.filter((r) => !r.ok);
if (failed.length > 0) {
  console.error(`${failed.length} statusline check(s) failed`);
  process.exit(1);
}
JS

node_exit=$?
if [ "$node_exit" -ne 0 ]; then
  cat "$output_file" >&2
  fail "statusline node harness failed (exit $node_exit)"
fi

if grep -q "^not ok" "$output_file"; then
  cat "$output_file" >&2
  fail "statusline node harness reported failing checks"
fi

# --- Clean-exit regression --------------------------------------------------
# /statusline off must clear the periodic refresh timer so the process can
# exit on its own. This probe enables then offs the footer WITHOUT firing
# session_shutdown (which would clear the timer unconditionally and mask a
# leak), and without process.exit, so a leaked setInterval keeps node alive
# and the bounded wait below catches it.
cat >"$fixture/clean-exit-probe.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL("./fm-quota-statusline.ts").href);
const eventHandlers = new Map();
let statusCmd = null;
const fakeCtx = () => ({
  cwd: "/Users/ediz/Developer/firstmate",
  model: { id: "gpt-5.6-terra" },
  thinkingLevel: "high",
  getContextUsage: () => ({ tokens: 272000, contextWindow: 200000, percent: 70.1 }),
  ui: { setFooter: () => {}, notify: () => {} },
});
const fakePi = {
  exec: async () => ({
    stdout: '{"providers":[{"provider":"codex","windows":[{"id":"weekly","label":"week","percentRemaining":95}]}]}',
    stderr: "", code: 0, killed: false,
  }),
  getThinkingLevel: () => "high",
  on: (ev, h) => {
    const a = eventHandlers.get(ev) ?? [];
    a.push(h);
    eventHandlers.set(ev, a);
  },
  registerCommand: (_n, o) => { statusCmd = o; },
};
mod.default(fakePi);
await statusCmd.handler("", fakeCtx());   // enable arms the periodic timer
await statusCmd.handler("off", fakeCtx()); // off must clear it
// Deliberately no session_shutdown and no process.exit: a clean
// implementation exits naturally once the periodic timer is cleared.
JS

( cd "$fixture" && node clean-exit-probe.mjs ) &
probe_pid=$!
probe_ok=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if ! kill -0 "$probe_pid" 2>/dev/null; then
    probe_ok=0
    break
  fi
done
if [ "$probe_ok" -ne 0 ]; then
  kill -9 "$probe_pid" 2>/dev/null
  wait "$probe_pid" 2>/dev/null
  fail "/statusline off did not clear the periodic timer: process stayed alive without session_shutdown"
fi
wait "$probe_pid" 2>/dev/null
probe_exit=$?
if [ "$probe_exit" -ne 0 ]; then
  fail "clean-exit probe exited non-zero ($probe_exit)"
fi
pass "clean-exit: /statusline off clears the periodic timer without session_shutdown"

pass "fm-quota-statusline rendering, staleness, narrow-width, and lifecycle checks"
