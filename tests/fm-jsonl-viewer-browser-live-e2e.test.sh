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
FIRST_SHORT_ID=short-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_ID=short-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DENSE_SHORT_ID=short-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SUPERVISOR_ID=supervisor-native-response.jsonl
FIRST_SHORT_DIR="$HOME_FIXTURE/state/short-agents/$FIRST_SHORT_ID"
SHORT_DIR="$HOME_FIXTURE/state/short-agents/$SHORT_ID"
DENSE_SHORT_DIR="$HOME_FIXTURE/state/short-agents/$DENSE_SHORT_ID"
FIRST_REPORT_ID=report-one
REPORT_ID=report-two
BRIEF_ID=brief-only
ARCHIVED_ID=archived-task
FIRST_REPORT_DIR="$HOME_FIXTURE/data/$FIRST_REPORT_ID"
REPORT_DIR="$HOME_FIXTURE/data/$REPORT_ID"
BRIEF_DIR="$HOME_FIXTURE/data/$BRIEF_ID"
ARCHIVED_DIR="$HOME_FIXTURE/data/$ARCHIVED_ID"
TOKEN=browser-fixture-token-value
SERVER_LOG="$TMP_ROOT/server.log"
mkdir -p "$FIRST_SHORT_DIR" "$SHORT_DIR" "$DENSE_SHORT_DIR" "$HOME_FIXTURE/state/branch-session" "$FIRST_REPORT_DIR" "$REPORT_DIR" "$BRIEF_DIR" "$ARCHIVED_DIR"
cat > "$HOME_FIXTURE/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
cat > "$HOME_FIXTURE/data/backlog.md" <<MARKDOWN
## In flight
- [ ] $REPORT_ID - Dashboard processing task (repo: viewer) (kind: ship)
- [ ] $FIRST_REPORT_ID - Delayed report task (repo: viewer) (kind: scout)
- [ ] tall-task-01 - Tall dashboard task 01 (repo: viewer) (kind: ship)
- [ ] tall-task-02 - Tall dashboard task 02 (repo: viewer) (kind: ship)
- [ ] tall-task-03 - Tall dashboard task 03 (repo: viewer) (kind: ship)
- [ ] tall-task-04 - Tall dashboard task 04 (repo: viewer) (kind: ship)
- [ ] tall-task-05 - Tall dashboard task 05 (repo: viewer) (kind: ship)
- [ ] tall-task-06 - Tall dashboard task 06 (repo: viewer) (kind: ship)
- [ ] tall-task-07 - Tall dashboard task 07 (repo: viewer) (kind: ship)
- [ ] tall-task-08 - Tall dashboard task 08 (repo: viewer) (kind: ship)
- [ ] tall-task-09 - Tall dashboard task 09 (repo: viewer) (kind: ship)
- [ ] tall-task-10 - Tall dashboard task 10 (repo: viewer) (kind: ship)

## Queued
- [ ] $BRIEF_ID - Held with task instructions blocked-by: upstream (repo: viewer) (kind: ship)
- [ ] no-document - Held without document blocked-by: upstream (repo: viewer) (kind: ship)

## Done
- [x] completed-task - Dashboard completed task (repo: viewer) (kind: ship)
MARKDOWN
cat > "$HOME_FIXTURE/data/done-archive.md" <<'MARKDOWN'
## Archived 2026-09
- [x] archived-task - Dashboard archived task (repo: viewer) (kind: ship)
MARKDOWN
cat > "$FIRST_SHORT_DIR/journal.jsonl" <<'JSONL'
{"type":"message_end","message":{"role":"assistant","timestamp":1779999999000,"content":[{"type":"text","text":"delayed first session"}]}}
JSONL
cat > "$FIRST_REPORT_DIR/report.md" <<'MARKDOWN'
# Delayed report

stale delayed report body
MARKDOWN
cat > "$REPORT_DIR/report.md" <<'MARKDOWN'
# Rendered report

Readable paragraph with `inline code` and [safe link](https://example.com).

- first item
- second item

> quoted evidence

| Check | Result |
| --- | --- |
| Browser | Passed |

```js
const literal = "<img id=code-unsafe src=x>";
```

<script id="report-script">globalThis.reportExecuted = true</script>
<img id="report-event" src=x onerror="globalThis.eventExecuted = true">
[unsafe link](javascript:globalThis.linkExecuted=true)
![remote image](https://example.invalid/should-not-load.png)
MARKDOWN
printf '# Superseded task brief\n\nThis must not replace the report.\n' > "$REPORT_DIR/brief.md"
printf '# Brief-only instructions\n\nVisible task instructions.\n' > "$BRIEF_DIR/brief.md"
printf '# Archived task brief\n\nVisible archived instructions.\n' > "$ARCHIVED_DIR/brief.md"
cat > "$SHORT_DIR/journal.jsonl" <<'JSONL'
{"type":"message_end","message":{"role":"assistant","timestamp":1779999999000,"content":[{"type":"text","text":"oldest ordered record"}]}}
{"type":"message_end","message":{"role":"assistant","timestamp":1780000000000,"content":[{"type":"text","text":"first tied record"}]}}
{"type":"message_end","message":{"role":"assistant","timestamp":1780000000000,"content":[{"type":"text","text":"<img id=unsafe src=x onerror=alert(1)>"},{"type":"toolCall","name":"read_material","arguments":{"material":"m1"}}]}}
JSONL
for index in $(seq 1 201); do
  printf '{"type":"message_end","message":{"role":"assistant","timestamp":%s,"content":[{"type":"text","text":"dense-browser-event-%s"}]}}\n' "$((1780001000000 + index))" "$index"
done > "$DENSE_SHORT_DIR/journal.jsonl"
{
  printf '%s\n' '{"type":"message","timestamp":1780000000000,"message":{"role":"user","content":[{"type":"text","text":"ordinary text mentions openai-codex-compat-native-response"}]}}'
  for index in $(seq 1 204); do
    if [ "$index" -eq 50 ] || [ "$index" -eq 150 ]; then
      printf '{"type":"custom_message","timestamp":%s,"customType":"openai-codex-compat-native-response","content":"hidden supervisor event %s"}\n' "$((1780000000000 + index))" "$index"
    else
      printf '{"type":"message","timestamp":%s,"message":{"role":"assistant","content":[{"type":"text","text":"supervisor record %s"}]}}\n' "$((1780000000000 + index))" "$index"
    fi
  done
  printf '%s\n' '{"type":"message","timestamp":1780000005000,"message":{"role":"user","content":[{"type":"text","text":"ordinary text mentions openai-codex-compat-native-response"}]}}'
} > "$HOME_FIXTURE/state/branch-session/$SUPERVISOR_ID"

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
  VIEWER_HOME="$HOME_FIXTURE" VIEWER_FIRST_SHORT_ID="$FIRST_SHORT_ID" VIEWER_SHORT_ID="$SHORT_ID" VIEWER_DENSE_SHORT_ID="$DENSE_SHORT_ID" VIEWER_SUPERVISOR_ID="$SUPERVISOR_ID" \
  VIEWER_FIRST_REPORT_ID="$FIRST_REPORT_ID" VIEWER_REPORT_ID="$REPORT_ID" VIEWER_BRIEF_ID="$BRIEF_ID" VIEWER_TOKEN="$TOKEN" \
  node --input-type=module <<'NODE'
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_ROOT);
const version = await fetch(`${process.env.CDP_URL}/json/version`).then(response => response.json());
const browser = await chromium.connectOverCDP(version.webSocketDebuggerUrl);
const page = await browser.contexts()[0].newPage();
await page.setViewportSize({ width: 1440, height: 1000 });
const evidenceDirectory = process.env.NO_MISTAKES_EVIDENCE_DIR;
if (evidenceDirectory) fs.mkdirSync(evidenceDirectory, { recursive: true });
async function captureEvidence(name) {
  if (!evidenceDirectory) return;
  await page.screenshot({ path: `${evidenceDirectory}/${name}.png`, fullPage: true });
}
let pendingTaskDelay = null;
let failNextTaskRequest = false;
function delayNextTaskRequest() {
  let markStarted;
  let release;
  const started = new Promise(resolve => { markStarted = resolve; });
  const released = new Promise(resolve => { release = resolve; });
  pendingTaskDelay = { markStarted, released };
  return { started, release };
}
await page.route("**/api/tasks", async route => {
  if (failNextTaskRequest) {
    failNextTaskRequest = false;
    await route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "task overview is temporarily unavailable" }) });
    return;
  }
  const delay = pendingTaskDelay;
  if (delay) {
    pendingTaskDelay = null;
    delay.markStarted();
    await delay.released;
  }
  await route.continue();
});
let delayFirst = false;
let releaseDelayed = () => {};
let markFirstRequestStarted;
const firstRequestStarted = new Promise(resolve => { markFirstRequestStarted = resolve; });
const delayedRelease = new Promise(resolve => { releaseDelayed = resolve; });
await page.route("**/api/events?*", async route => {
  const url = new URL(route.request().url());
  if (delayFirst && url.searchParams.get("id") === process.env.VIEWER_FIRST_SHORT_ID) {
    delayFirst = false;
    markFirstRequestStarted();
    await delayedRelease;
  }
  await route.continue();
});
let delayFirstReport = false;
let releaseDelayedReport = () => {};
let markFirstReportRequestStarted;
const firstReportRequestStarted = new Promise(resolve => { markFirstReportRequestStarted = resolve; });
const delayedReportRelease = new Promise(resolve => { releaseDelayedReport = resolve; });
let delayUserScrollReport = false;
let releaseUserScrollReport = () => {};
let markUserScrollReportStarted;
const userScrollReportStarted = new Promise(resolve => { markUserScrollReportStarted = resolve; });
const userScrollReportRelease = new Promise(resolve => { releaseUserScrollReport = resolve; });
await page.route("**/api/task-document?*", async route => {
  const url = new URL(route.request().url());
  if (delayUserScrollReport && url.searchParams.get("id") === process.env.VIEWER_REPORT_ID) {
    delayUserScrollReport = false;
    markUserScrollReportStarted();
    await userScrollReportRelease;
  }
  if (delayFirstReport && url.searchParams.get("id") === process.env.VIEWER_FIRST_REPORT_ID) {
    delayFirstReport = false;
    markFirstReportRequestStarted();
    await delayedReportRelease;
  }
  await route.continue();
});
let remoteAssetRequests = 0;
let rejectedSessionRequests = 0;
page.on("request", request => {
  if (request.url().startsWith("https://example.invalid/")) remoteAssetRequests += 1;
  if (request.url().includes("/api/sessions") && request.headers().authorization === "Bearer invalid-saved-token") rejectedSessionRequests += 1;
});
let failed;
let storagePage;
try {
  await page.goto(process.env.VIEWER_URL, { waitUntil: "domcontentloaded", timeout: 3000 });
  await page.locator("#task-follow").uncheck();
  failNextTaskRequest = true;
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#remember-token").check();
  await page.locator("#connect").click();
  await page.locator("#task-status").filter({ hasText: "task overview is temporarily unavailable" }).waitFor({ state: "visible", timeout: 3000 });
  if (!(await page.locator("#sessions .empty").textContent()).startsWith("Task loading failed:")) throw new Error("left task list presented a loading error as an empty result");
  if (!await page.locator("#task-groups .empty").evaluateAll(nodes => nodes.length === 3 && nodes.every(node => node.textContent.startsWith("Task loading failed:")))) throw new Error("task groups presented a loading error as empty categories");
  await captureEvidence("viewer-task-error-state");
  const initialTaskDelay = delayNextTaskRequest();
  await page.locator("#connect").click();
  await initialTaskDelay.started;
  if (await page.locator("#task-status").textContent() !== "Loading task status…") throw new Error("initial task loading state was not explicit");
  if (await page.locator("#task-counts strong").evaluateAll(nodes => nodes.some(node => node.textContent === "0"))) throw new Error("unloaded task counts were presented as authoritative zeros");
  if (await page.locator("#sessions .empty").textContent() !== "Loading task status…") throw new Error("left task list presented loading as an empty result");
  if (!await page.locator("#task-groups .empty").evaluateAll(nodes => nodes.length === 3 && nodes.every(node => node.textContent === "Loading task status…"))) throw new Error("task groups presented loading as empty categories");
  await captureEvidence("viewer-task-loading-state");
  await page.locator("#source").selectOption("short");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SHORT_ID }).click();
  await page.getByText("<img id=unsafe src=x onerror=alert(1)>", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  initialTaskDelay.release();
  await page.locator("#source").selectOption("tasks");
  await page.getByText("Dashboard processing task", { exact: true }).first().waitFor({ state: "visible", timeout: 5000 });
  if (!(await page.locator("#task-status").textContent()).includes("UTC+8")) throw new Error("task refresh time was not labelled UTC+8");
  if (await page.locator('#task-groups .task-card[data-category="processing"]').count() !== 12) throw new Error("processing task category was not rendered");
  if (await page.locator('#task-groups [data-category="completed"]').count()) throw new Error("completed task dashboard section was rendered");
  if (await page.locator('#task-counts').getByText("Completed", { exact: true }).count()) throw new Error("completed task counter was rendered");
  if (await page.locator('#task-groups .task-card[data-category="held"]').count() !== 2) throw new Error("held task category was not rendered separately");
  if (await page.locator('#task-groups .task-card[data-category="history"]').count() !== 1) throw new Error("archived task category was not rendered");
  await page.locator('#task-groups .task-card[data-category="history"]').first().click();
  await page.getByRole("heading", { name: "Archived task brief" }).waitFor({ state: "visible", timeout: 3000 });
  if (!await page.locator("#task-document-report").isDisabled()) throw new Error("archived brief-only task did not show its unavailable report");
  await captureEvidence("viewer-task-dashboard-loaded");
  const refreshTaskDelay = delayNextTaskRequest();
  await page.locator("#task-follow").check();
  await refreshTaskDelay.started;
  if (await page.locator("#task-status").textContent() !== "Refreshing task status…") throw new Error("background task refresh state was not explicit");
  if (await page.locator('#task-counts strong').evaluateAll(nodes => nodes.map(node => node.textContent).join(",")) !== "12,2,1") throw new Error("background task refresh did not preserve loaded counts");
  const dashboardReportCard = page.locator('#task-groups .task-card[data-category="processing"]').filter({ hasText: "Dashboard processing task" });
  if (!await page.locator("#task-groups").evaluate(element => element.getBoundingClientRect().bottom > window.innerHeight)) throw new Error("dashboard fixture was not tall enough to reproduce the off-screen detail");
  await dashboardReportCard.click();
  await page.locator("#task-document-type").filter({ hasText: "Task report" }).waitFor({ state: "visible", timeout: 3000 });
  if (!await page.locator("#task-detail").evaluate(element => {
    const bounds = element.getBoundingClientRect();
    return bounds.top >= 0 && bounds.top < window.innerHeight;
  })) throw new Error("dashboard task click left the rendered report outside the viewport");
  refreshTaskDelay.release();
  await page.locator("#task-status").filter({ hasText: "UTC+8" }).waitFor({ state: "visible", timeout: 5000 });
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  if (!await page.getByRole("heading", { name: "Rendered report" }).isVisible()) throw new Error("task refresh replaced the selected report display");
  await page.locator("#task-document-type").filter({ hasText: "Task report" }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.locator("#task-document-brief").isDisabled() || await page.locator("#task-document-report").isDisabled()) throw new Error("both-document task did not expose both document selectors");
  await page.locator("#task-document-brief").click();
  await page.getByRole("heading", { name: "Superseded task brief" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#task-document-type").filter({ hasText: "Task brief" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#task-document-report").click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  await page.getByRole("button", { name: /Held with task instructions/ }).first().click();
  delayUserScrollReport = true;
  await dashboardReportCard.click();
  await userScrollReportStarted;
  await page.mouse.move(1430, 500);
  await page.mouse.down();
  await page.mouse.up();
  await page.mouse.wheel(0, -600);
  const deliberateScrollY = await page.evaluate(() => window.scrollY);
  releaseUserScrollReport();
  await page.locator("#task-document-type").filter({ hasText: "Task report" }).waitFor({ state: "visible", timeout: 3000 });
  await page.waitForTimeout(100);
  const completedScrollY = await page.evaluate(() => window.scrollY);
  if (Math.abs(completedScrollY - deliberateScrollY) > 2) throw new Error(`completed task document request overrode deliberate user scrolling: ${deliberateScrollY} -> ${completedScrollY}`);
  await dashboardReportCard.click();
  if (!await page.locator("#task-detail").evaluate(element => element.getBoundingClientRect().top >= -1 && element.getBoundingClientRect().top < window.innerHeight)) throw new Error("repeated dashboard click did not restore the task detail to the viewport");
  await captureEvidence("viewer-task-detail-canonical-report");
  await page.locator("#open-task-report").click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  await captureEvidence("viewer-canonical-report-view");
  await page.locator("#source").selectOption("tasks");
  await page.getByRole("button", { name: /Held with task instructions/ }).first().waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("This must not replace the report.", { exact: true }).count()) throw new Error("task brief took precedence over its report");
  await page.getByRole("button", { name: /Held with task instructions/ }).first().click();
  await page.getByRole("heading", { name: "Brief-only instructions" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#task-document-type").filter({ hasText: "Task brief" }).waitFor({ state: "visible", timeout: 3000 });
  if (!await page.locator("#task-document-report").isDisabled() || await page.locator("#task-document-report").textContent() !== "Report unavailable") throw new Error("brief-only task did not make its missing report explicit");
  fs.writeFileSync(`${process.env.VIEWER_HOME}/data/${process.env.VIEWER_BRIEF_ID}/report.md`, "# Newly available report\n\nCanonical report discovered after connection.\n");
  await page.locator("#open-task-report").waitFor({ state: "visible", timeout: 5000 });
  await page.locator("#open-task-report").click();
  await page.getByRole("heading", { name: "Newly available report" }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.locator("#source").inputValue() !== "report") throw new Error("newly discovered canonical report did not open in report view");
  await page.locator("#source").selectOption("tasks");
  await page.getByRole("button", { name: /Held without document/ }).first().click();
  await page.getByText("No canonical task document is available for this task.", { exact: true }).waitFor({ state: "visible", timeout: 3000 });

  delayFirstReport = true;
  await page.locator('#task-groups .task-card[data-category="processing"]').filter({ hasText: "Delayed report task" }).click();
  await firstReportRequestStarted;
  await dashboardReportCard.click();
  await page.locator('#task-groups .task-card[data-category="held"]').filter({ hasText: "Held with task instructions" }).click();
  await dashboardReportCard.click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  const staleTaskDocumentResponse = page.waitForResponse(response => new URL(response.url()).searchParams.get("id") === process.env.VIEWER_FIRST_REPORT_ID);
  releaseDelayedReport();
  await (await staleTaskDocumentResponse).finished();
  await page.waitForTimeout(100);
  if (await page.getByText("stale delayed report body", { exact: true }).count()) throw new Error("stale task document replaced the current task selection");

  const backlog = `${process.env.VIEWER_HOME}/data/backlog.md`;
  fs.writeFileSync(backlog, `## In flight\n- [ ] ${process.env.VIEWER_FIRST_REPORT_ID} - Delayed report task (repo: viewer) (kind: scout)\n\n## Queued\n- [ ] ${process.env.VIEWER_BRIEF_ID} - Held with task instructions blocked-by: upstream (repo: viewer) (kind: ship)\n- [ ] no-document - Held without document blocked-by: upstream (repo: viewer) (kind: ship)\n\n## Done\n- [x] completed-task - Dashboard completed task (repo: viewer) (kind: ship)\n- [x] ${process.env.VIEWER_REPORT_ID} - Dashboard processing task (repo: viewer) (kind: ship)\n`);
  await page.locator('#sessions .task-card[data-category="completed"]').filter({ hasText: "Dashboard processing task" }).first().waitFor({ state: "visible", timeout: 5000 });
  if (await page.locator('#task-groups [data-category="completed"]').count()) throw new Error("completed task reappeared as a dedicated dashboard group after refresh");

  await page.reload({ waitUntil: "domcontentloaded" });
  await page.getByText("Dashboard processing task", { exact: true }).first().waitFor({ state: "visible", timeout: 5000 });
  if (await page.locator("#token").inputValue() !== process.env.VIEWER_TOKEN) throw new Error("opted-in token was not restored after reload");
  await page.locator("#forget").click();
  if (await page.locator("#token").inputValue()) throw new Error("forget did not clear the in-memory token");
  if (await page.evaluate(() => localStorage.length)) throw new Error("forget did not clear the saved token");
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#connect").click();
  await page.getByText("Dashboard processing task", { exact: true }).first().waitFor({ state: "visible", timeout: 5000 });
  if (await page.evaluate(() => localStorage.length)) throw new Error("token was persisted without explicit opt-in");
  await page.evaluate(() => localStorage.setItem("firstmate.jsonlViewer.accessToken.v1", "invalid-saved-token"));
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.locator("#task-status").filter({ hasText: "Saved access token was rejected" }).waitFor({ state: "visible", timeout: 3000 });
  await page.waitForTimeout(1200);
  if (rejectedSessionRequests !== 1) throw new Error(`invalid saved token retried ${rejectedSessionRequests} times`);
  if (await page.evaluate(() => localStorage.length) || await page.locator("#token").inputValue()) throw new Error("invalid saved token was not cleared");

  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#connect").click();
  await page.locator("#source").selectOption("short");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SHORT_ID }).click();
  await page.locator(".event-card").first().waitFor({ state: "visible", timeout: 3000 });
  const initialOrder = await page.locator(".event-content").allInnerTexts();
  if (initialOrder[0] !== "first tied record" || !initialOrder[1]?.startsWith("<img id=unsafe src=x onerror=alert(1)>") || initialOrder[2] !== "oldest ordered record") throw new Error(`initial records were not newest-first with stable ties: ${initialOrder.join("|")}`);
  const unsafeContentParts = await page.locator(".event-content").filter({ hasText: "<img id=unsafe" }).locator(":scope > *").allInnerTexts();
  if (!unsafeContentParts[0]?.includes("<img id=unsafe") || !unsafeContentParts[1]?.includes("Tool call: read_material")) throw new Error("newest-first rendering changed within-record content order");
  const literal = await page.locator(".event-content").filter({ hasText: "<img id=unsafe" }).textContent();
  if (!literal.includes("<img id=unsafe")) throw new Error("log markup was not shown literally");
  if (await page.locator("#unsafe").count()) throw new Error("log markup executed as HTML");
  if (!await page.getByText("Tool call: read_material").count()) throw new Error("tool call was not expandable");
  await page.locator("#source").selectOption("supervisor");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SUPERVISOR_ID.replace(/\.jsonl$/, "") }).click();
  await page.getByText("ordinary text mentions openai-codex-compat-native-response", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("hidden supervisor event 150", { exact: true }).count()) throw new Error("supervisor native response was rendered on initial load");
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#connect").click();
  await page.locator("#source").selectOption("supervisor");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SUPERVISOR_ID.replace(/\.jsonl$/, "") }).click();
  await page.getByText("ordinary text mentions openai-codex-compat-native-response", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("hidden supervisor event 150", { exact: true }).count()) throw new Error("supervisor native response was rendered after page reload");
  await page.locator("#from-start").click();
  await page.getByText("supervisor record 1", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("hidden supervisor event 50", { exact: true }).count()) throw new Error("supervisor native response was rendered after reload from start");
  await page.locator("#load-more").click();
  await page.getByText("supervisor record 204", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("hidden supervisor event 50", { exact: true }).count() || await page.getByText("hidden supervisor event 150", { exact: true }).count()) throw new Error("supervisor native response was rendered during pagination");
  const supervisorJournal = `${process.env.VIEWER_HOME}/state/branch-session/${process.env.VIEWER_SUPERVISOR_ID}`;
  fs.appendFileSync(supervisorJournal, '{"type":"custom_message","timestamp":1780000003000,"customType":"openai-codex-compat-native-response","content":"hidden live supervisor event"}\n');
  fs.appendFileSync(supervisorJournal, '{"type":"message","timestamp":1780000003001,"message":{"role":"assistant","content":[{"type":"text","text":"visible live supervisor record"}]}}\n');
  await page.getByText("visible live supervisor record", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("hidden live supervisor event", { exact: true }).count()) throw new Error("supervisor native response was rendered during live append");
  await page.locator("#source").selectOption("short");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_DENSE_SHORT_ID }).click();
  await page.getByText("dense-browser-event-201", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  const denseInitialOrder = await page.locator(".event-content").allInnerTexts();
  if (denseInitialOrder[0] !== "dense-browser-event-201" || denseInitialOrder.at(-1) !== "dense-browser-event-2" || denseInitialOrder.includes("dense-browser-event-1")) throw new Error("dense initial load did not show the actual newest 200 records");
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#connect").click();
  await page.locator("#source").selectOption("short");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_DENSE_SHORT_ID }).click();
  await page.getByText("dense-browser-event-201", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if ((await page.locator(".event-content").allInnerTexts())[0] !== "dense-browser-event-201") throw new Error("dense reload did not keep the actual newest record first");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SHORT_ID }).click();
  await page.getByText("<img id=unsafe src=x onerror=alert(1)>", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  delayFirst = true;
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_FIRST_SHORT_ID }).click();
  await firstRequestStarted;
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SHORT_ID }).click();
  await page.getByText("<img id=unsafe src=x onerror=alert(1)>", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("delayed first session", { exact: true }).count()) throw new Error("stale session content was rendered before its delayed response");
  const staleResponse = page.waitForResponse(response => new URL(response.url()).searchParams.get("id") === process.env.VIEWER_FIRST_SHORT_ID);
  releaseDelayed();
  await (await staleResponse).finished();
  await page.waitForTimeout(100);
  if (await page.getByText("delayed first session", { exact: true }).count()) throw new Error("stale session content was rendered after its delayed response");
  const journal = `${process.env.VIEWER_HOME}/state/short-agents/${process.env.VIEWER_SHORT_ID}/journal.jsonl`;
  const retainedDetails = page.locator(".event-content").filter({ hasText: "<img id=unsafe" }).locator("details").first();
  await retainedDetails.locator("summary").click();
  if (!await retainedDetails.evaluate(element => element.open)) throw new Error("tool details did not open before live append");
  const retainedRecord = page.getByText("oldest ordered record", { exact: true });
  await retainedRecord.scrollIntoViewIfNeeded();
  const retainedTop = (await retainedRecord.boundingBox())?.y;
  fs.appendFileSync(journal, '{"type":"message_end","message":{"role":"toolResult","timestamp":1780000001000,"toolName":"read_material","content":[{"type":"text","text":"partial live');
  await page.locator("#notice").filter({ hasText: "Waiting for a newline" }).waitFor({ state: "visible", timeout: 3000 });
  fs.appendFileSync(journal, ' append"}]}}\n');
  await page.getByText("partial live append", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  const appendedOrder = await page.locator(".event-content").allInnerTexts();
  if (appendedOrder[0] !== "partial live append" || appendedOrder.at(-1) !== "oldest ordered record") throw new Error(`live append was not placed newest-first: ${appendedOrder.join("|")}`);
  if (!await retainedDetails.evaluate(element => element.open)) throw new Error("live append collapsed an expanded record");
  const retainedTopAfterAppend = (await retainedRecord.boundingBox())?.y;
  if (retainedTop === undefined || retainedTopAfterAppend === undefined || Math.abs(retainedTopAfterAppend - retainedTop) > 2) throw new Error("live append moved the record being read out of position");
  const retainedTopBeforeFilterGrowth = (await retainedRecord.boundingBox())?.y;
  fs.appendFileSync(journal, '{"type":"layout-changing-record-type-with-a-deliberately-wide-filter-label","role":"layout-changing-record-role-with-a-deliberately-wide-filter-label","timestamp":1780000001000.5,"content":[{"type":"text","text":"layout changing live append"}]}\n');
  await page.getByText("layout changing live append", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  const retainedTopAfterFilterGrowth = (await retainedRecord.boundingBox())?.y;
  if (retainedTopBeforeFilterGrowth === undefined || retainedTopAfterFilterGrowth === undefined || Math.abs(retainedTopAfterFilterGrowth - retainedTopBeforeFilterGrowth) > 2) throw new Error("live filter-option growth moved the record being read out of position");
  await page.locator("#role-filter").selectOption("assistant");
  const filteredRetainedTop = (await retainedRecord.boundingBox())?.y;
  fs.appendFileSync(journal, '{"type":"message_end","message":{"role":"toolResult","timestamp":1780000001001,"content":[{"type":"text","text":"filtered live append"}]}}\n');
  await page.getByText("filtered live append", { exact: true }).waitFor({ state: "attached", timeout: 3000 });
  if (await page.getByText("filtered live append", { exact: true }).isVisible()) throw new Error("role filter exposed a nonmatching live record");
  const filteredRetainedTopAfterAppend = (await retainedRecord.boundingBox())?.y;
  if (filteredRetainedTop === undefined || filteredRetainedTopAfterAppend === undefined || Math.abs(filteredRetainedTopAfterAppend - filteredRetainedTop) > 2) throw new Error("filtered live append moved the record being read out of position");
  await page.locator("#role-filter").selectOption("all");
  await page.locator("#event-search").fill("no-event-can-match-this");
  if (await page.locator(".event-card:visible").count()) throw new Error("search did not filter rendered events");
  await page.locator("#event-search").fill("");
  if (await page.locator(".event-card:visible").count() !== 6) throw new Error("live append did not preserve all events");
  fs.renameSync(journal, `${journal}.rotated`);
  fs.writeFileSync(journal, Array.from({ length: 201 }, (_, index) => JSON.stringify({ type: "message_end", message: { role: "assistant", timestamp: 1780000002000 + index, content: [{ type: "text", text: `replacement generation record ${index + 1}` }] } })).join("\n") + "\n");
  await page.getByText("replacement generation record 201", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  const generationOrder = await page.locator("#events > *").evaluateAll(nodes => nodes.map(node => node.classList.contains("boundary") ? `boundary:${node.textContent}` : node.querySelector(".event-content")?.textContent || ""));
  if (generationOrder[0] !== "replacement generation record 201" || generationOrder[199] !== "replacement generation record 2" || !generationOrder[200]?.startsWith("boundary:The journal was rotated.") || !generationOrder.slice(201).some(value => value.includes("oldest ordered record"))) throw new Error(`dense rotation boundary did not separate the newest replacement tail from the prior generation: ${generationOrder.join("|")}`);
  if (!await retainedDetails.evaluate(element => element.open)) throw new Error("journal rotation collapsed retained record details");
  if (!await page.locator("#journal-filters").isVisible() || !await page.locator("#journal-actions").isVisible() || !await page.locator("#events").isVisible()) throw new Error("journal controls were hidden in journal mode");
  await page.locator("#source").selectOption("report");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_REPORT_ID }).click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.locator("#journal-filters").isVisible() || await page.locator("#journal-actions").isVisible() || await page.locator("#events").isVisible()) throw new Error("journal-only controls remained visible in report mode");
  if (!await page.locator(".markdown-body table").count()) throw new Error("Markdown table was not rendered");
  if (!await page.locator(".markdown-body pre code").filter({ hasText: "const literal" }).count()) throw new Error("fenced code was not rendered");
  if (!await page.locator(".markdown-body blockquote").filter({ hasText: "quoted evidence" }).count()) throw new Error("blockquote was not rendered");
  if (await page.locator(".markdown-body li").count() !== 2) throw new Error("Markdown list was not rendered");
  if (await page.locator("#report-script").count()) throw new Error("raw report HTML became active DOM");
  if (await page.locator("#report-event").count()) throw new Error("raw report event handler became active DOM");
  if (await page.evaluate(() => globalThis.reportExecuted === true || globalThis.eventExecuted === true || globalThis.linkExecuted === true)) throw new Error("report script, event handler, or dangerous link executed");
  const unsafeLink = page.getByText("unsafe link (blocked link)", { exact: true });
  if (!await unsafeLink.count() || await unsafeLink.evaluate(element => element.hasAttribute("href"))) throw new Error("dangerous link became navigable");
  if (await page.locator(".markdown-body img").count() || remoteAssetRequests) throw new Error("report rendering fetched a remote image");
  if (!await page.locator(".report-source pre").filter({ hasText: "javascript:globalThis" }).count()) throw new Error("plain report source fallback was unavailable");
  const report = `${process.env.VIEWER_HOME}/data/${process.env.VIEWER_REPORT_ID}/report.md`;
  fs.appendFileSync(report, "\n## Refreshed section\n\nreport refresh marker\n");
  await page.getByRole("heading", { name: "Refreshed section" }).waitFor({ state: "visible", timeout: 3000 });
  let releaseArtifactReport = () => {};
  let markArtifactReportStarted;
  const artifactReportStarted = new Promise(resolve => { markArtifactReportStarted = resolve; });
  const artifactReportRelease = new Promise(resolve => { releaseArtifactReport = resolve; });
  await page.route("**/api/report?*", async route => {
    const url = new URL(route.request().url());
    if (url.searchParams.get("id") === process.env.VIEWER_FIRST_REPORT_ID) {
      markArtifactReportStarted();
      await artifactReportRelease;
    }
    await route.continue();
  });
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_FIRST_REPORT_ID }).click();
  await artifactReportStarted;
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_REPORT_ID }).click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  const staleReportResponse = page.waitForResponse(response => new URL(response.url()).searchParams.get("id") === process.env.VIEWER_FIRST_REPORT_ID);
  releaseArtifactReport();
  await (await staleReportResponse).finished();
  await page.waitForTimeout(100);
  if (await page.getByText("stale delayed report body", { exact: true }).count()) throw new Error("stale report response replaced the current report");

  storagePage = await browser.contexts()[0].newPage();
  await storagePage.addInitScript(() => {
    Object.defineProperty(window, "localStorage", { configurable: true, get() { throw new DOMException("denied", "SecurityError"); } });
  });
  await storagePage.goto(process.env.VIEWER_URL, { waitUntil: "domcontentloaded", timeout: 3000 });
  await storagePage.locator("#token").fill(process.env.VIEWER_TOKEN);
  await storagePage.locator("#remember-token").check();
  await storagePage.locator("#connect").click();
  await storagePage.getByText("Browser storage is unavailable", { exact: false }).waitFor({ state: "visible", timeout: 3000 });
  await storagePage.getByText("Dashboard processing task", { exact: true }).first().waitFor({ state: "visible", timeout: 5000 });
  await storagePage.close();
} catch (error) {
  failed = error;
} finally {
  releaseDelayed();
  releaseDelayedReport();
  if (storagePage && !storagePage.isClosed()) await storagePage.close();
  await page.close();
}
if (failed) throw failed;
process.exit(0);
NODE

pass 'browser safely renders and refreshes task Markdown while preserving journal follow and switch isolation'
