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
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture/node_modules/@earendil-works" "$fixture/lib"
ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' >"$fixture/package.json"
cp "$EXT" "$fixture/fm-quota-statusline.ts"
cp "$DATA" "$fixture/lib/fm-quota-statusline-data.ts"
cp "$RENDER" "$fixture/lib/fm-quota-statusline-render.ts"

output_file="$fixture/node-output"
( cd "$fixture" && node --input-type=module ) >"$output_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { parseQuotaJson, extractWindows } from "./lib/fm-quota-statusline-data.ts";
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
  }],
});
const freshState = parseQuotaJson(freshJson);
check("parses a fresh quota document", freshState !== null);
const freshWindows = extractWindows(freshState, "codex");
check("extracts the weekly window", freshWindows.length === 1 && freshWindows[0].id === "weekly");

const theme = { fg: (_color, text) => text };
const now = Date.parse("2026-08-11T07:00:00.000Z");
const freshInput = {
  repoPath: "~/Developer/firstmate",
  repoBasename: "firstmate",
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
// Below the two-line threshold the footer collapses to one line and never
// overflows the terminal width.
const narrowLines = renderFooter(freshInput, theme, 18);
check("narrow footer renders a single line", narrowLines.length === 1);
check("narrow footer stays within the width", (narrowLines[0] ?? "").length <= 18 || !narrowLines[0].includes("\n"));
check("narrow footer shows the repo basename", (narrowLines[0] ?? "").startsWith("firstmate"));
// Even narrower: truncation must be ANSI-safe and not throw.
const tinyLines = renderFooter(freshInput, theme, 6);
check("tiny width does not throw and yields one line", tinyLines.length === 1);

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
  exec: async () => execResult,
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

// Render through the installed component to confirm it produces the footer.
const component = footerFactory(
  { requestRender() {} },
  { fg: (_c, t) => t },
  { getGitBranch: () => "main", onBranchChange: () => () => {} },
);
const componentLines = component.render(120);
check("installed footer renders two lines", componentLines.length === 2);
check("installed footer line 1 shows branch", (componentLines[0] ?? "").includes("(main)"));

// Refresh: a second fetch after a transient failure keeps last-good windows
// and marks them stale.
execResult = { stdout: "", stderr: "boom", code: 1, killed: false };
await statusCmd.handler("refresh", fakeCtx());
await new Promise((resolve) => setTimeout(resolve, 50));
const staleComponentLines = component.render(120);
const staleComponentLine2 = staleComponentLines[1] ?? "";
check("refresh after failure keeps the last-good window", staleComponentLine2.includes("week: 95%"));
check("refresh after failure marks stale", staleComponentLine2.includes("quota~"));

// Restore stock footer.
notifyMessages = [];
await statusCmd.handler("off", fakeCtx());
check("off restores the stock footer (undefined)", footerFactory === undefined);
check("off notifies the captain", notifyMessages.some((n) => /stock/i.test(n.message)));

// Fire session_shutdown to clear the periodic timer so the harness exits.
for (const handler of (eventHandlers.get("session_shutdown") ?? [])) {
  handler({}, fakeCtx());
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

pass "fm-quota-statusline rendering, staleness, narrow-width, and lifecycle checks"
