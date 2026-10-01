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
FIRST_SHORT_DIR="$HOME_FIXTURE/state/short-agents/$FIRST_SHORT_ID"
SHORT_DIR="$HOME_FIXTURE/state/short-agents/$SHORT_ID"
FIRST_REPORT_ID=report-one
REPORT_ID=report-two
BRIEF_ID=brief-only
FIRST_REPORT_DIR="$HOME_FIXTURE/data/$FIRST_REPORT_ID"
REPORT_DIR="$HOME_FIXTURE/data/$REPORT_ID"
BRIEF_DIR="$HOME_FIXTURE/data/$BRIEF_ID"
TOKEN=browser-fixture-token-value
SERVER_LOG="$TMP_ROOT/server.log"
mkdir -p "$FIRST_SHORT_DIR" "$SHORT_DIR" "$HOME_FIXTURE/state/branch-session" "$FIRST_REPORT_DIR" "$REPORT_DIR" "$BRIEF_DIR"
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
  VIEWER_HOME="$HOME_FIXTURE" VIEWER_FIRST_SHORT_ID="$FIRST_SHORT_ID" VIEWER_SHORT_ID="$SHORT_ID" \
  VIEWER_FIRST_REPORT_ID="$FIRST_REPORT_ID" VIEWER_REPORT_ID="$REPORT_ID" VIEWER_BRIEF_ID="$BRIEF_ID" VIEWER_TOKEN="$TOKEN" \
  node --input-type=module <<'NODE'
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_ROOT);
const version = await fetch(`${process.env.CDP_URL}/json/version`).then(response => response.json());
const browser = await chromium.connectOverCDP(version.webSocketDebuggerUrl);
const page = await browser.contexts()[0].newPage();
let pendingTaskDelay = null;
function delayNextTaskRequest() {
  let markStarted;
  let release;
  const started = new Promise(resolve => { markStarted = resolve; });
  const released = new Promise(resolve => { release = resolve; });
  pendingTaskDelay = { markStarted, released };
  return { started, release };
}
await page.route("**/api/tasks", async route => {
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
await page.route("**/api/task-document?*", async route => {
  const url = new URL(route.request().url());
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
  const initialTaskDelay = delayNextTaskRequest();
  await page.locator("#token").fill(process.env.VIEWER_TOKEN);
  await page.locator("#remember-token").check();
  await page.locator("#connect").click();
  await initialTaskDelay.started;
  if (await page.locator("#task-status").textContent() !== "Loading task status…") throw new Error("initial task loading state was not explicit");
  if (await page.locator("#task-counts strong").evaluateAll(nodes => nodes.some(node => node.textContent === "0"))) throw new Error("unloaded task counts were presented as authoritative zeros");
  await page.locator("#source").selectOption("short");
  await page.locator(".session-button").filter({ hasText: process.env.VIEWER_SHORT_ID }).click();
  await page.getByText("<img id=unsafe src=x onerror=alert(1)>", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  initialTaskDelay.release();
  await page.locator("#source").selectOption("tasks");
  await page.getByText("Dashboard processing task", { exact: true }).first().waitFor({ state: "visible", timeout: 5000 });
  if (!(await page.locator("#task-status").textContent()).includes("UTC+8")) throw new Error("task refresh time was not labelled UTC+8");
  if (await page.locator('#task-groups .task-card[data-category="processing"]').count() !== 2) throw new Error("processing task category was not rendered");
  if (await page.locator('#task-groups .task-card[data-category="completed"]').count() !== 1) throw new Error("completed task category was not rendered");
  if (await page.locator('#task-groups .task-card[data-category="held"]').count() !== 2) throw new Error("held task category was not rendered separately");
  if (await page.locator('#task-groups .task-card[data-category="history"]').count() !== 1) throw new Error("archived task category was not rendered");
  const refreshTaskDelay = delayNextTaskRequest();
  await refreshTaskDelay.started;
  if (await page.locator("#task-status").textContent() !== "Refreshing task status…") throw new Error("background task refresh state was not explicit");
  if (await page.locator('#task-counts strong').evaluateAll(nodes => nodes.map(node => node.textContent).join(",")) !== "2,2,1,1") throw new Error("background task refresh did not preserve loaded counts");
  refreshTaskDelay.release();
  await page.locator("#task-status").filter({ hasText: "UTC+8" }).waitFor({ state: "visible", timeout: 5000 });
  await page.getByRole("button", { name: /Dashboard processing task/ }).first().click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#task-document-type").filter({ hasText: "Task report" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#open-task-report").click();
  await page.locator("#source").selectOption("tasks");
  await page.getByRole("button", { name: /Held with task instructions/ }).first().waitFor({ state: "visible", timeout: 3000 });
  if (await page.getByText("This must not replace the report.", { exact: true }).count()) throw new Error("task brief took precedence over its report");
  await page.getByRole("button", { name: /Held with task instructions/ }).first().click();
  await page.getByRole("heading", { name: "Brief-only instructions" }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#task-document-type").filter({ hasText: "Task brief" }).waitFor({ state: "visible", timeout: 3000 });
  fs.writeFileSync(`${process.env.VIEWER_HOME}/data/${process.env.VIEWER_BRIEF_ID}/report.md`, "# Newly available report\n\nCanonical report discovered after connection.\n");
  await page.locator("#open-task-report").waitFor({ state: "visible", timeout: 5000 });
  await page.locator("#open-task-report").click();
  await page.getByRole("heading", { name: "Newly available report" }).waitFor({ state: "visible", timeout: 3000 });
  if (await page.locator("#source").inputValue() !== "report") throw new Error("newly discovered canonical report did not open in report view");
  await page.locator("#source").selectOption("tasks");
  await page.getByRole("button", { name: /Held without document/ }).first().click();
  await page.getByText("No canonical task document is available for this task.", { exact: true }).waitFor({ state: "visible", timeout: 3000 });

  delayFirstReport = true;
  await page.getByRole("button", { name: /Delayed report task/ }).first().click();
  await firstReportRequestStarted;
  await page.getByRole("button", { name: /Dashboard processing task/ }).first().click();
  await page.getByRole("heading", { name: "Rendered report" }).waitFor({ state: "visible", timeout: 3000 });
  const staleTaskDocumentResponse = page.waitForResponse(response => new URL(response.url()).searchParams.get("id") === process.env.VIEWER_FIRST_REPORT_ID);
  releaseDelayedReport();
  await (await staleTaskDocumentResponse).finished();
  await page.waitForTimeout(100);
  if (await page.getByText("stale delayed report body", { exact: true }).count()) throw new Error("stale task document replaced the current task selection");

  const backlog = `${process.env.VIEWER_HOME}/data/backlog.md`;
  fs.writeFileSync(backlog, `## In flight\n- [ ] ${process.env.VIEWER_FIRST_REPORT_ID} - Delayed report task (repo: viewer) (kind: scout)\n\n## Queued\n- [ ] ${process.env.VIEWER_BRIEF_ID} - Held with task instructions blocked-by: upstream (repo: viewer) (kind: ship)\n- [ ] no-document - Held without document blocked-by: upstream (repo: viewer) (kind: ship)\n\n## Done\n- [x] completed-task - Dashboard completed task (repo: viewer) (kind: ship)\n- [x] ${process.env.VIEWER_REPORT_ID} - Dashboard processing task (repo: viewer) (kind: ship)\n`);
  await page.locator('.task-card[data-category="completed"]').filter({ hasText: "Dashboard processing task" }).first().waitFor({ state: "visible", timeout: 5000 });

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
  await page.locator(".event-card").waitFor({ state: "visible", timeout: 3000 });
  const literal = await page.locator(".event-content").textContent();
  if (!literal.includes("<img id=unsafe")) throw new Error("log markup was not shown literally");
  if (await page.locator("#unsafe").count()) throw new Error("log markup executed as HTML");
  if (!await page.getByText("Tool call: read_material").count()) throw new Error("tool call was not expandable");
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
  fs.appendFileSync(journal, '{"type":"message_end","message":{"role":"toolResult","timestamp":1780000001000,"toolName":"read_material","content":[{"type":"text","text":"partial live');
  await page.locator("#notice").filter({ hasText: "Waiting for a newline" }).waitFor({ state: "visible", timeout: 3000 });
  fs.appendFileSync(journal, ' append"}]}}\n');
  await page.getByText("partial live append", { exact: true }).waitFor({ state: "visible", timeout: 3000 });
  await page.locator("#event-search").fill("no-event-can-match-this");
  if (await page.locator(".event-card:visible").count()) throw new Error("search did not filter rendered events");
  await page.locator("#event-search").fill("");
  if (await page.locator(".event-card:visible").count() !== 2) throw new Error("live append did not preserve both events");
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
