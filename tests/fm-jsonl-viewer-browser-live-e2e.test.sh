#!/usr/bin/env bash
# Browser-level read-only regression against an already-running Chrome CDP
# endpoint. The guard opens and closes only its own page and never launches or
# closes the browser.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_JSONL_VIEWER_BROWSER_LIVE node npm curl

CDP_URL=${FM_JSONL_VIEWER_CDP_URL:-http://127.0.0.1:9333}
PLAYWRIGHT_ROOT="$(npm root -g)/playwright-core"
if [ ! -f "$PLAYWRIGHT_ROOT/package.json" ]; then
  [ "${FM_JSONL_VIEWER_BROWSER_LIVE:-${FM_LIVE:-}}" = 1 ] && fail "playwright-core is unavailable at $PLAYWRIGHT_ROOT"
  printf 'skip: live: playwright-core absent\n'
  exit 0
fi
if ! curl -sS --max-time 2 "$CDP_URL/json/version" >/dev/null 2>&1; then
  [ "${FM_JSONL_VIEWER_BROWSER_LIVE:-${FM_LIVE:-}}" = 1 ] && fail "Chrome CDP endpoint is unavailable at $CDP_URL"
  printf 'skip: live: Chrome CDP endpoint absent\n'
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-jsonl-viewer-browser)
HOME_FIXTURE="$TMP_ROOT/home"
SHORT_ID=short-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHORT_DIR="$HOME_FIXTURE/state/short-agents/$SHORT_ID"
TOKEN=browser-fixture-token-value
SERVER_LOG="$TMP_ROOT/server.log"
mkdir -p "$SHORT_DIR" "$HOME_FIXTURE/state/branch-session"
cat > "$SHORT_DIR/journal.jsonl" <<'JSONL'
{"type":"message_end","message":{"role":"assistant","timestamp":1780000000000,"content":[{"type":"text","text":"<img id=unsafe src=x onerror=alert(1)>"},{"type":"toolCall","name":"read_material","arguments":{"material":"m1"}}]}}
JSONL

FM_HOME="$HOME_FIXTURE" FM_JSONL_VIEWER_TOKEN="$TOKEN" FM_JSONL_VIEWER_PORT=0 \
  node "$ROOT/bin/fm-jsonl-viewer.mjs" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 100); do
  PORT=$(sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$SERVER_LOG")
  [ -n "$PORT" ] && break
  sleep 0.05
done
[ -n "${PORT:-}" ] || fail "viewer did not report its browser-test port"

env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  PLAYWRIGHT_ROOT="$PLAYWRIGHT_ROOT" CDP_URL="$CDP_URL" VIEWER_URL="http://127.0.0.1:$PORT" \
  VIEWER_HOME="$HOME_FIXTURE" VIEWER_SHORT_ID="$SHORT_ID" VIEWER_TOKEN="$TOKEN" \
  node --input-type=module <<'NODE'
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_ROOT);
const version = await fetch(`${process.env.CDP_URL}/json/version`).then(response => response.json());
const browser = await chromium.connectOverCDP(version.webSocketDebuggerUrl);
const page = await browser.contexts()[0].newPage();
let failed;
try {
  await page.goto(process.env.VIEWER_URL, { waitUntil: "domcontentloaded", timeout: 3000 });
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#connect").click();
  await page.locator(".event-card").waitFor({ state: "visible", timeout: 3000 });
  const literal = await page.locator(".event-content").textContent();
  if (!literal.includes("<img id=unsafe")) throw new Error("log markup was not shown literally");
  if (await page.locator("#unsafe").count()) throw new Error("log markup executed as HTML");
  if (!await page.getByText("Tool call: read_material").count()) throw new Error("tool call was not expandable");
  const journal = `${process.env.VIEWER_HOME}/state/short-agents/${process.env.VIEWER_SHORT_ID}/journal.jsonl`;
  fs.appendFileSync(journal, '{"type":"message_end","message":{"role":"toolResult","timestamp":1780000001000,"toolName":"read_material","content":[{"type":"text","text":"live append"}]}}\n');
  await page.getByText("live append", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#event-search").fill("no-event-can-match-this");
  if (await page.locator(".event-card:visible").count()) throw new Error("search did not filter rendered events");
  await page.locator("#event-search").fill("");
  if (await page.locator(".event-card:visible").count() !== 2) throw new Error("live append did not preserve both events");
} catch (error) {
  failed = error;
} finally {
  await page.close();
}
if (failed) throw failed;
process.exit(0);
NODE

pass 'browser renders log text inertly, expands tool calls, filters events and follows appends without reloading'
