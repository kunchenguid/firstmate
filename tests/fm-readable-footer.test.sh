#!/usr/bin/env bash
# Focused deterministic checks for Firstmate's labelled Pi footer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-readable-footer)
EXT="$ROOT/.pi/extensions/fm-readable-footer.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
trap fm_test_cleanup EXIT

assert_present "$EXT" "tracked readable Pi footer extension is missing"
command -v node >/dev/null 2>&1 || { echo "skip: node not found for readable Pi footer test"; exit 0; }
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed Pi package not found"; exit 0; }

fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture/node_modules/@earendil-works"
cp "$EXT" "$fixture/fm-readable-footer.ts"
ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$fixture/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

out=$(cd "$fixture" && EXT="$fixture/fm-readable-footer.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { visibleWidth } from "@earendil-works/pi-tui";

const footer = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
const usage = (input, output, cacheRead, cacheWrite, total) => ({
  input, output, cacheRead, cacheWrite,
  totalTokens: input + output + cacheRead + cacheWrite,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total },
});
const entries = [
  { type: "message", message: { role: "assistant", usage: usage(1000, 200, 3000, 100, 1.25) } },
  { type: "message", message: { role: "toolResult", usage: usage(10, 20, 30, 40, 0.25) } },
  { type: "compaction", usage: usage(100, 50, 200, 0, 0.5) },
  { type: "message", message: { role: "assistant", usage: usage(500, 100, 4500, 0, 0.75) } },
];
const totals = footer.aggregateUsage(entries);
if (JSON.stringify(totals) !== JSON.stringify({
  input: 1610, output: 370, cacheRead: 7730, cacheWrite: 140, cost: 2.75, latestCacheHit: 90,
})) throw new Error(`usage aggregation changed: ${JSON.stringify(totals)}`);

const plainTheme = { fg: (_color, text) => text };
const base = {
  ...totals,
  cwd: process.cwd(), branch: "fm/footer", sessionName: "Readable footer", model: "claude-sonnet",
  contextWindow: 272000, contextPercent: 23.8,
  subscription: true, automaticCompaction: true,
};
const wide = footer.renderFooter(base, 240, plainTheme);
const joined = wide.join("\n");
for (const label of ["Directory ", "Session ", "Model ", "Input ", "Output ", "Cache read ", "Cache write ", "Cache hit ", "Cost ", "Context "]) {
  if (!joined.includes(label)) throw new Error(`missing clear footer label: ${label}`);
}
if (!joined.includes("(subscription)")) throw new Error("subscription cost is not explained");
if (!joined.includes("(automatic compaction)")) throw new Error("automatic compaction is not explained");
if (/↑|↓|\bCH\d|\bR\d|\(sub\)|\(auto\)/.test(joined)) throw new Error(`abbreviation leaked into footer: ${joined}`);

const metered = footer.renderFooter({ ...base, subscription: false }, 240, plainTheme).join("\n");
if (!metered.includes("Cost $2.750 (metered usage)")) throw new Error("metered cost is not explained");

const missing = footer.renderFooter({
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0,
  cwd: "/tmp/not-a-repo", subscription: false, automaticCompaction: false,
}, 80, plainTheme).join("\n");
if (!missing.includes("Directory /tmp/not-a-repo") || !missing.includes("Model unavailable") || !missing.includes("Context unknown")) {
  throw new Error(`missing values are unclear: ${missing}`);
}
for (const width of [1, 8, 20, 40, 80, 120, 240]) {
  const lines = footer.renderFooter(base, width, plainTheme);
  if (lines.length !== 2) throw new Error(`expected two footer lines at width ${width}`);
  for (const line of lines) {
    if (visibleWidth(line) > width) throw new Error(`footer exceeded width ${width}: ${line}`);
  }
}

const handlers = new Map();
const pi = { on(name, handler) { handlers.set(name, handler); } };
footer.default(pi);
let footerSets = 0;
const context = {
  mode: "print", isProjectTrusted: () => true,
  ui: { setFooter() { footerSets += 1; } },
};
handlers.get("session_start")({}, context);
context.mode = "json";
handlers.get("session_start")({}, context);
context.mode = "rpc";
handlers.get("session_start")({}, context);
context.mode = "tui";
context.isProjectTrusted = () => false;
handlers.get("session_start")({}, context);
if (footerSets !== 0) throw new Error("footer extension acted outside a trusted interactive TUI");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "readable Pi footer checks failed: $out"
[ -z "$out" ] || fail "readable Pi footer test printed output: $out"
pass "Pi footer aggregates usage, explains labels and billing, handles missing data, stays width-bounded, and is TUI-only"
