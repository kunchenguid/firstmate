#!/usr/bin/env bash
# Portable public-interface regressions for Firstmate's Pi quota status extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail "node not found for Pi quota status test"
command -v npm >/dev/null 2>&1 || fail "npm not found for Pi quota status test"

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed @earendil-works/pi-coding-agent package not found"
[ -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] \
  || fail "installed Pi package is missing pi-tui"

TMP_ROOT=$(fm_test_tmproot fm-pi-quota-status)
FIXTURE="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/quota.calls"
STDIN_LOG="$TMP_ROOT/quota.stdin"
MODE_FILE="$TMP_ROOT/quota.mode"
PID_LOG="$TMP_ROOT/quota.pids"
DESCENDANT_PID_LOG="$TMP_ROOT/quota.descendant-pids"
SURVIVOR_LOG="$TMP_ROOT/quota.survivors"
mkdir -p "$FIXTURE/.pi/extensions/lib" "$FIXTURE/node_modules/@earendil-works" "$FAKEBIN"
cp "$ROOT/.pi/extensions/fm-pi-quota-status.ts" "$FIXTURE/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-pi-quota-status.ts" "$FIXTURE/.pi/extensions/lib/"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' > "$FIXTURE/package.json"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_QUOTA_TEST_CALLS:?}"
if IFS= read -r input; then
  printf 'data:%s\n' "$input" >> "${FM_QUOTA_TEST_STDIN:?}"
else
  printf '%s\n' eof >> "${FM_QUOTA_TEST_STDIN:?}"
fi
mode=$(cat "${FM_QUOTA_TEST_MODE:?}")
case "$mode" in
  fail)
    exit 1
    ;;
  malformed)
    printf '%s\n' '{not-json'
    exit 0
    ;;
  overflow)
    node -e 'process.stdout.write("x".repeat(8192))'
    exit 0
    ;;
  slow)
    printf '%s\n' "$$" >> "${FM_QUOTA_TEST_PIDS:?}"
    sleep 30
    exit 0
    ;;
  delayed_fail)
    printf '%s\n' "$$" >> "${FM_QUOTA_TEST_PIDS:?}"
    node -e 'setTimeout(() => process.exit(0), 200)'
    exit 1
    ;;
  leader_exit)
    node -e '
      const fs = require("node:fs");
      fs.appendFileSync(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, `${process.pid}\n`);
      setTimeout(() => {
        fs.appendFileSync(process.env.FM_QUOTA_TEST_SURVIVORS, `${process.pid}\n`);
      }, 1000);
    ' &
    exit 0
    ;;
  leader_exit_closed_stdio)
    descendants_before=$(wc -l < "${FM_QUOTA_TEST_DESCENDANT_PIDS:?}")
    node -e '
      const fs = require("node:fs");
      fs.appendFileSync(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, `${process.pid}\n`);
      setTimeout(() => {
        fs.appendFileSync(process.env.FM_QUOTA_TEST_SURVIVORS, `${process.pid}\n`);
      }, 1000);
    ' </dev/null >/dev/null 2>/dev/null &
    while [ "$(wc -l < "${FM_QUOTA_TEST_DESCENDANT_PIDS:?}")" -le "$descendants_before" ]; do
      sleep 0.01
    done
    exit 0
    ;;
  stale)
    FM_QUOTA_TEST_STALE=1 exec node "${FM_QUOTA_TEST_FIXTURE:?}"
    ;;
  success)
    exec node "${FM_QUOTA_TEST_FIXTURE:?}"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$TMP_ROOT/quota-fixture.mjs" <<'JS'
const configuredNow = Number(process.env.FM_QUOTA_TEST_NOW_MS);
const now = Number.isFinite(configuredNow) && configuredNow > 0 ? configuredNow : Date.now();
const generatedAt = new Date(now - (process.env.FM_QUOTA_TEST_STALE === "1" ? 60 * 60 * 1000 : 0)).toISOString();
const state = { status: "fresh", stale: false, refreshedAt: generatedAt, sourcesTried: ["fake"] };
const reset = (milliseconds) => new Date(now + milliseconds).toISOString();
const providers = [
  {
    provider: "claude",
    label: "Claude",
    source: "oauth",
    plan: "max",
    windows: [
      { id: "session", label: "session", kind: "session", percentRemaining: 72.5, resetsAt: reset(2 * 60 * 60 * 1000) },
      { id: "week", label: "week", kind: "weekly", percentRemaining: 61, resetsAt: reset(4 * 24 * 60 * 60 * 1000) },
    ],
    credits: { unlimited: true, unit: "credits" },
    state,
  },
  {
    provider: "codex",
    label: "Codex",
    source: "oauth",
    plan: "pro",
    windows: [
      { id: "weekly", label: "week", kind: "weekly", percentRemaining: 94, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
      { id: "model:spark:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", percentRemaining: 100, resetsAt: reset(5 * 60 * 60 * 1000) },
      { id: "model:spark:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", percentRemaining: 100, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
    ],
    credits: { remaining: 0, unlimited: false, unit: "credits" },
    state,
  },
  {
    provider: "grok",
    label: "Grok",
    source: "web",
    windows: [
      { id: "credits", label: "credits", kind: "credits", percentRemaining: 48, resetText: "next month" },
    ],
    state,
  },
];
process.stdout.write(JSON.stringify({ generatedAt, schemaVersion: 5, providers }));
JS

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

export FM_QUOTA_TEST_CALLS="$CALLS"
export FM_QUOTA_TEST_STDIN="$STDIN_LOG"
export FM_QUOTA_TEST_MODE="$MODE_FILE"
export FM_QUOTA_TEST_PIDS="$PID_LOG"
export FM_QUOTA_TEST_DESCENDANT_PIDS="$DESCENDANT_PID_LOG"
export FM_QUOTA_TEST_SURVIVORS="$SURVIVOR_LOG"
export FM_QUOTA_TEST_FIXTURE="$TMP_ROOT/quota-fixture.mjs"
export PATH="$FAKEBIN:$PATH"
printf '%s\n' success > "$MODE_FILE"
: > "$CALLS"
: > "$STDIN_LOG"
: > "$PID_LOG"
: > "$DESCENDANT_PID_LOG"
: > "$SURVIVOR_LOG"

out=$(cd "$FIXTURE" && \
  EXT="$FIXTURE/.pi/extensions/fm-pi-quota-status.ts" \
  LIB="$FIXTURE/.pi/extensions/lib/fm-pi-quota-status.ts" \
  node --input-type=module 2>&1 <<'JS'
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { visibleWidth } from "@earendil-works/pi-tui";

const extensionModule = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
const quotaModule = await import(`${pathToFileURL(process.env.LIB).href}?test=${Date.now()}`);
const {
  createFirstmateQuotaStatusExtension,
  runQuotaAxiJson,
} = extensionModule;
const {
  formatQuotaStatus,
  parseQuotaAxiJson,
  quotaProviderForPiProvider,
  selectActiveProviderQuota,
} = quotaModule;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function waitFor(predicate, message, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await sleep(10);
  }
  throw new Error(message);
}
function plain(value) {
  return String(value ?? "").replace(/\x1b\[[0-9;]*m/g, "");
}
function report(now = Date.now()) {
  const state = { status: "fresh", stale: false, refreshedAt: new Date(now).toISOString(), sourcesTried: ["fake"] };
  return {
    generatedAt: new Date(now).toISOString(),
    schemaVersion: 3,
    providers: [
      {
        provider: "claude",
        label: "Claude",
        source: "oauth",
        plan: "max",
        windows: [
          { id: "session", label: "session", kind: "session", percentRemaining: 72.5, resetsAt: new Date(now + 2 * 60 * 60 * 1000).toISOString() },
        ],
        credits: { unlimited: true, unit: "credits" },
        state,
      },
      {
        provider: "codex",
        label: "Codex",
        source: "oauth",
        plan: "pro",
        windows: [
          { id: "weekly", label: "week", kind: "weekly", percentRemaining: 94, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString() },
          { id: "spark-session", label: "GPT-5.3-Codex-Spark session", kind: "model", percentRemaining: 100, resetsAt: new Date(now + 5 * 60 * 60 * 1000).toISOString() },
          { id: "spark-week", label: "GPT-5.3-Codex-Spark week", kind: "model", percentRemaining: 100, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString() },
        ],
        credits: { remaining: 0, unlimited: false, unit: "credits" },
        state,
      },
    ],
  };
}

// Parser and formatter public interfaces.
const now = Date.now();
const parsed = parseQuotaAxiJson(JSON.stringify(report(now)));
assert(parsed, "valid quota-axi schema-3 JSON was rejected");
const currentSchema = report(now);
currentSchema.schemaVersion = 5;
assert(parseQuotaAxiJson(JSON.stringify(currentSchema)), "valid quota-axi schema-5 JSON was rejected");
assert(quotaProviderForPiProvider("openai-codex") === "codex", "openai-codex provider mapping failed");
assert(quotaProviderForPiProvider("anthropic") === "claude", "anthropic provider mapping failed");
assert(quotaProviderForPiProvider("github-copilot") === "copilot", "GitHub Copilot provider mapping failed");
assert(quotaProviderForPiProvider("kimi-coding") === "kimi", "Kimi Coding provider mapping failed");
assert(quotaProviderForPiProvider("xai") === "grok", "xAI provider mapping failed");
assert(quotaProviderForPiProvider("openai") === null, "direct OpenAI was incorrectly mapped to Codex quota");
for (const customProvider of ["claude", "codex", "copilot", "cursor", "grok", "kimi", "OPENAI-CODEX", " openai-codex "]) {
  assert(quotaProviderForPiProvider(customProvider) === null, `custom provider ${customProvider} was treated as canonical`);
  assert(
    selectActiveProviderQuota(parsed, customProvider, { nowMs: now }).kind === "unsupported",
    `custom provider ${customProvider} was assigned unrelated local quota`,
  );
}

const codex = selectActiveProviderQuota(parsed, "openai-codex", { nowMs: now });
assert(codex.kind === "fresh", "active Codex provider was not selected");
const full = formatQuotaStatus(codex, 400, now);
for (const expected of [
  "Quota Codex (plan pro)",
  "week 94% left",
  "GPT-5.3-Codex-Spark session 100% left",
  "GPT-5.3-Codex-Spark week 100% left",
  "credits 0",
  "reset",
]) {
  assert(full.includes(expected), `complete format omitted ${expected}: ${full}`);
}
assert(visibleWidth(full) <= 400, "complete format exceeded its width");
const narrow = formatQuotaStatus(codex, 72, now);
assert(narrow.includes("narrow") && narrow.includes("3 windows"), `narrow format was not explicit: ${narrow}`);
assert(!narrow.includes("week 94%"), `narrow format silently presented a partial window set: ${narrow}`);
assert(visibleWidth(narrow) <= 72, "narrow format exceeded its width");
const veryNarrow = formatQuotaStatus(codex, 24, now);
assert(veryNarrow.includes("narrow"), `very narrow format lost its explicit degradation: ${veryNarrow}`);
assert(visibleWidth(veryNarrow) <= 24, "very narrow format exceeded its width");

const claude = selectActiveProviderQuota(parsed, "anthropic", { nowMs: now });
assert(claude.kind === "fresh", "active Claude provider was not selected");
const claudeFull = formatQuotaStatus(claude, 240, now);
assert(claudeFull.includes("plan max") && claudeFull.includes("credits unlimited"), "plan or unlimited credits were omitted");

const staleRaw = report(now - 60 * 60 * 1000);
const staleParsed = parseQuotaAxiJson(JSON.stringify(staleRaw));
assert(staleParsed, "stale fixture did not parse structurally");
const stale = selectActiveProviderQuota(staleParsed, "openai-codex", { nowMs: now });
assert(stale.kind === "stale", "old report was not classified stale");
const staleText = formatQuotaStatus(stale, 100, now);
assert(staleText.includes("stale") && !staleText.includes("94%"), "stale values were presented as fresh");
assert(parseQuotaAxiJson("{broken") === null, "malformed JSON was accepted");
const malformed = report(now);
malformed.providers[1].windows[0].percentRemaining = 101;
const malformedParsed = parseQuotaAxiJson(JSON.stringify(malformed));
assert(malformedParsed, "malformed provider fixture should remain structurally parseable");
assert(selectActiveProviderQuota(malformedParsed, "openai-codex", { nowMs: now }).kind === "malformed", "bad percentage was accepted");
const missingWindows = report(now);
delete missingWindows.providers[1].windows;
const missingWindowKind = report(now);
delete missingWindowKind.providers[1].windows[0].kind;
const unknownWindowKind = report(now);
unknownWindowKind.providers[1].windows[0].kind = "annual";
const paddedWindowKind = report(now);
paddedWindowKind.providers[1].windows[0].kind = " weekly ";
const unknownCreditUnit = report(now);
unknownCreditUnit.providers[1].credits.unit = "bananas";
const paddedCreditUnit = report(now);
paddedCreditUnit.providers[1].credits.unit = " credits ";
const missingProviderSource = report(now);
delete missingProviderSource.providers[1].source;
const unknownProviderSource = report(now);
unknownProviderSource.providers[1].source = "tunnel";
const paddedProviderSource = report(now);
paddedProviderSource.providers[1].source = " oauth ";
const unknownProviderStatus = report(now);
unknownProviderStatus.providers[1].state.status = "maybe";
const paddedProviderStatus = report(now);
paddedProviderStatus.providers[1].state.status = " fresh ";
const missingSourcesTried = report(now);
delete missingSourcesTried.providers[1].state.sourcesTried;
for (const [malformedReport, description] of [
  [missingWindows, "missing windows"],
  [missingWindowKind, "missing window kind"],
  [unknownWindowKind, "unknown window kind"],
  [paddedWindowKind, "normalized window kind"],
  [unknownCreditUnit, "unknown credit unit"],
  [paddedCreditUnit, "normalized credit unit"],
  [missingProviderSource, "missing provider source"],
  [unknownProviderSource, "unknown provider source"],
  [paddedProviderSource, "normalized provider source"],
  [unknownProviderStatus, "unknown provider status"],
  [paddedProviderStatus, "normalized provider status"],
  [missingSourcesTried, "missing state sources"],
]) {
  const structurallyParsed = parseQuotaAxiJson(JSON.stringify(malformedReport));
  assert(structurallyParsed, `${description} fixture should remain structurally parseable`);
  assert(
    selectActiveProviderQuota(structurallyParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `${description} was accepted as fresh`,
  );
}
const uppercaseProvider = report(now);
uppercaseProvider.providers[1].provider = "CODEX";
const uppercaseProviderParsed = parseQuotaAxiJson(JSON.stringify(uppercaseProvider));
assert(uppercaseProviderParsed, "uppercase provider fixture did not parse structurally");
assert(
  selectActiveProviderQuota(uppercaseProviderParsed, "openai-codex", { nowMs: now }).kind === "unavailable",
  "normalized quota provider ID was selected as fresh",
);
const emptyWindows = report(now);
emptyWindows.providers[1].windows = [];
const emptyWindowsParsed = parseQuotaAxiJson(JSON.stringify(emptyWindows));
assert(emptyWindowsParsed, "empty-window fixture did not parse structurally");
const emptyWindowsView = selectActiveProviderQuota(emptyWindowsParsed, "openai-codex", { nowMs: now });
assert(emptyWindowsView.kind === "fresh", "valid fresh empty-window quota was discarded");
const emptyWindowsText = formatQuotaStatus(emptyWindowsView, 400, now);
assert(emptyWindowsText.includes("no quota windows"), `empty-window state was not explicit: ${emptyWindowsText}`);
assert(emptyWindowsText.includes("plan pro"), `empty-window state omitted plan: ${emptyWindowsText}`);
assert(emptyWindowsText.includes("credits 0"), `empty-window state omitted credits: ${emptyWindowsText}`);
assert(selectActiveProviderQuota(parsed, "custom-proxy", { nowMs: now }).kind === "unsupported", "unsupported provider was not isolated");
const ansiReport = report(now);
ansiReport.providers[1].label = "Co\x1b[31mdex";
ansiReport.providers[1].windows[0].label = "週\x1b[0m quota";
const ansiParsed = parseQuotaAxiJson(JSON.stringify(ansiReport));
assert(ansiParsed, "ANSI fixture did not parse structurally");
const ansiView = selectActiveProviderQuota(ansiParsed, "openai-codex", { nowMs: now });
const ansiText = formatQuotaStatus(ansiView, 400, now);
assert(!ansiText.includes("\x1b"), "producer-controlled ANSI escaped into the status");
assert(ansiText.includes("週 quota") && visibleWidth(ansiText) <= 400, "wide-character quota formatting was not display-width safe");

// The subprocess public interface is argv-bounded, stdin-closed, and output-bounded.
const direct = runQuotaAxiJson({ timeoutMs: 1000, maxOutputBytes: 1024 * 1024 });
const directResult = await direct.promise;
assert(directResult.kind === "ok", `fake quota-axi process failed: ${directResult.kind}`);

const officialBaseUrls = {
  anthropic: "https://api.anthropic.com",
  "github-copilot": "https://api.individual.githubcopilot.com",
  "kimi-coding": "https://api.kimi.com/coding",
  "openai-codex": "https://chatgpt.com/backend-api",
  xai: "https://api.x.ai/v1",
};
function fixtureModel(provider, id = "fixture-model", baseUrl = officialBaseUrls[provider] ?? "https://custom.example.invalid") {
  return { provider, id, baseUrl };
}
function makePi(factory, provider = "openai-codex", mode = "tui", providerOptions = {}) {
  const handlers = new Map();
  const statuses = new Map([["aaa-unrelated", "UNRELATED_STATUS"]]);
  const widgets = new Map();
  const writes = [];
  let footer = "BUILTIN_FOOTER";
  const theme = { fg(_color, text) { return `\x1b[2m${text}\x1b[0m`; } };
  const pi = {
    on(event, handler) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
  };
  factory(pi);
  const ctx = {
    mode,
    model: provider ? fixtureModel(provider, "fixture-model", providerOptions.baseUrl) : undefined,
    modelRegistry: {
      getProvider() {
        return { auth: { oauth: { isSubscription: providerOptions.subscription !== false } } };
      },
      isUsingOAuth() {
        return providerOptions.authType !== "api_key";
      },
      async getProviderAuth() {
        if (providerOptions.authError) throw new Error("fixture auth failure");
        if (providerOptions.authUnavailable) return undefined;
        return {
          auth: providerOptions.authBaseUrl ? { baseUrl: providerOptions.authBaseUrl } : {},
          source: providerOptions.authType === "api_key" ? "fixture API key" : "OAuth",
        };
      },
    },
    ui: {
      theme,
      setStatus(key, value) {
        writes.push(["status", key, value]);
        if (value === undefined) statuses.delete(key);
        else statuses.set(key, value);
      },
      setWidget(key, content, options) {
        writes.push(["widget", key, content]);
        if (content === undefined) {
          widgets.delete(key);
          return;
        }
        const component = Array.isArray(content)
          ? { render() { return content; }, invalidate() {} }
          : content({ requestRender() {} }, theme);
        widgets.set(key, { component, options });
      },
      setFooter(value) {
        writes.push(["footer", value]);
        footer = value ?? "BUILTIN_FOOTER";
      },
    },
  };
  async function emit(event, payload = {}, overrideCtx = ctx) {
    for (const handler of handlers.get(event) ?? []) await handler(payload, overrideCtx);
  }
  function widgetText(width = 200, key = "firstmate-quota") {
    const widget = widgets.get(key);
    return plain(widget ? widget.component.render(width).join("\n") : "");
  }
  return {
    ctx,
    emit,
    statuses,
    widgets,
    writes,
    widgetText,
    get footer() { return footer; },
    get widgetWriteCount() { return writes.filter(([kind]) => kind === "widget").length; },
  };
}

const baselineResizeListeners = process.stdout.listenerCount("resize");
const lifecycle = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 80,
  timeoutMs: 500,
  maxOutputBytes: 1024 * 1024,
}));
await lifecycle.emit("session_start", { reason: "startup" });
await waitFor(
  () => lifecycle.widgetText(400).includes("GPT-5.3-Codex-Spark week"),
  "startup did not render every Codex quota window",
);
assert(lifecycle.widgets.get("firstmate-quota")?.options?.placement === "belowEditor", "quota did not use its width-aware footer row");
assert(lifecycle.widgetText(72).includes("narrow") && lifecycle.widgetText(72).includes("3 windows"), "composed narrow footer did not degrade explicitly");
assert(lifecycle.statuses.get("aaa-unrelated") === "UNRELATED_STATUS", "quota widget replaced an unrelated extension status");
assert(lifecycle.footer === "BUILTIN_FOOTER", "quota widget replaced Pi's built-in footer");
assert(process.stdout.listenerCount("resize") === baselineResizeListeners, "session start installed a direct resize listener");

await lifecycle.emit("model_select", { model: fixtureModel("anthropic", "claude-fixture") });
await waitFor(
  () => lifecycle.widgetText(240).includes("Quota Claude"),
  "model change did not refresh active-provider selection",
);
const callsBeforeCadence = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await sleep(180);
const callsAfterCadence = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterCadence > callsBeforeCadence, "bounded cadence did not refresh during a long-lived session");

await lifecycle.emit("session_shutdown", { reason: "reload" });
assert(!lifecycle.widgets.has("firstmate-quota"), "shutdown did not clear the quota widget");
assert(lifecycle.statuses.get("aaa-unrelated") === "UNRELATED_STATUS", "shutdown cleared an unrelated status");
assert(lifecycle.footer === "BUILTIN_FOOTER", "shutdown changed Pi's built-in footer");
assert(process.stdout.listenerCount("resize") === baselineResizeListeners, "shutdown changed resize listeners");
const callsAtShutdown = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await sleep(120);
const callsAfterShutdown = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterShutdown === callsAtShutdown, "shutdown leaked a refresh timer");

for (const reason of ["reload", "new", "resume", "fork"]) {
  lifecycle.ctx.model = fixtureModel("xai", "grok-fixture");
  await lifecycle.emit("session_start", { reason });
  await waitFor(
    () => lifecycle.widgetText(240).includes("Quota Grok"),
    `${reason} did not refresh quota widget`,
  );
  assert(process.stdout.listenerCount("resize") === baselineResizeListeners, `${reason} changed resize listeners`);
  await lifecycle.emit("session_shutdown", { reason: "reload" });
  assert(process.stdout.listenerCount("resize") === baselineResizeListeners, `${reason} leaked resize listeners`);
}

class FakeClock {
  constructor(nowMs) {
    this.nowMs = nowMs;
    this.nextId = 1;
    this.tasks = new Map();
    this.timers = {
      setTimeout: (callback, delayMs) => this.add(callback, delayMs, null),
      clearTimeout: (id) => this.tasks.delete(id),
      setInterval: (callback, delayMs) => this.add(callback, delayMs, delayMs),
      clearInterval: (id) => this.tasks.delete(id),
    };
  }
  add(callback, delayMs, intervalMs) {
    const id = this.nextId++;
    this.tasks.set(id, { id, callback, at: this.nowMs + delayMs, intervalMs });
    return id;
  }
  jump(milliseconds) {
    this.nowMs += milliseconds;
  }
  advance(milliseconds) {
    const target = this.nowMs + milliseconds;
    for (;;) {
      const task = [...this.tasks.values()]
        .filter((candidate) => candidate.at <= target)
        .sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!task) break;
      this.nowMs = task.at;
      if (task.intervalMs === null) this.tasks.delete(task.id);
      else task.at += task.intervalMs;
      task.callback();
    }
    this.nowMs = target;
  }
}

const fakeStart = Date.now();
const fakeClock = new FakeClock(fakeStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(fakeStart);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const expiring = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => fakeClock.nowMs,
  timers: fakeClock.timers,
}));
await expiring.emit("session_start", { reason: "startup" });
await waitFor(() => expiring.widgetText(400).includes("week 94% left"), "fake clock fixture did not publish fresh quota");
await writeFile(process.env.FM_QUOTA_TEST_MODE, "fail\n");
const writesBeforeFailedRefresh = expiring.widgetWriteCount;
fakeClock.advance(5 * 60 * 1000);
await waitFor(() => expiring.widgetWriteCount > writesBeforeFailedRefresh, "failed refresh did not republish the still-fresh report");
assert(expiring.widgetText(400).includes("week 94% left"), "failed refresh discarded quota before its freshness deadline");
const writesBeforeDelayedExpiry = expiring.widgetWriteCount;
fakeClock.jump(60 * 1000);
assert(expiring.widgetWriteCount === writesBeforeDelayedExpiry, "fake clock unexpectedly ran the delayed expiry callback");
assert(expiring.widgetText(400).includes("stale"), "rendering presented quota past its freshness deadline");
assert(!expiring.widgetText(400).includes("94%"), "rendering presented expired quota values as fresh");
fakeClock.advance(0);
assert(expiring.widgetWriteCount > writesBeforeDelayedExpiry, "expiry callback did not republish the stale view");
await expiring.emit("session_shutdown", { reason: "quit" });
assert(fakeClock.tasks.size === 0, "shutdown leaked a fake-clock refresh or expiry timer");
delete process.env.FM_QUOTA_TEST_NOW_MS;

const nonTui = makePi(createFirstmateQuotaStatusExtension({ refreshMs: 40, timeoutMs: 80 }), "openai-codex", "print");
await nonTui.emit("session_start", { reason: "startup" });
assert(!nonTui.widgets.has("firstmate-quota"), "print mode installed a TUI quota widget");
await nonTui.emit("session_shutdown", { reason: "quit" });

for (const [description, providerOptions, expected] of [
  ["API-key auth", { authType: "api_key" }, "non-subscription auth"],
  ["model endpoint override", { baseUrl: "https://proxy.example.invalid" }, "custom endpoint"],
  ["auth endpoint override", { authBaseUrl: "https://gateway.example.invalid" }, "custom endpoint"],
]) {
  const callsBefore = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
  const instance = makePi(
    createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 100 }),
    "anthropic",
    "tui",
    providerOptions,
  );
  await instance.emit("session_start", { reason: "startup" });
  await waitFor(
    () => instance.widgetText(240).includes(expected),
    `${description} was not identified explicitly: ${instance.widgetText(240)}`,
  );
  await sleep(30);
  const callsAfter = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
  assert(callsAfter === callsBefore, `${description} invoked quota-axi for unrelated local quota`);
  await instance.emit("session_shutdown", { reason: "quit" });
}

async function statusCase(mode, expected, options = {}) {
  await writeFile(process.env.FM_QUOTA_TEST_MODE, `${mode}\n`);
  const instance = makePi(createFirstmateQuotaStatusExtension({
    refreshMs: 60_000,
    timeoutMs: options.timeoutMs ?? 100,
    maxOutputBytes: options.maxOutputBytes ?? 1024 * 1024,
    command: options.command,
    width: () => 200,
  }));
  await instance.emit("session_start", { reason: "startup" });
  await waitFor(
    () => instance.widgetText(200).includes(expected),
    `${mode} did not render ${expected}: ${instance.widgetText(200)}`,
  );
  await instance.emit("session_shutdown", { reason: "quit" });
  return instance;
}

await statusCase("malformed", "malformed data");
await statusCase("fail", "unavailable");
await statusCase("stale", "stale");
await statusCase("overflow", "unavailable", { maxOutputBytes: 128 });
await statusCase("success", "unavailable", { command: "quota-axi-definitely-missing" });

const pidsBeforeUnsupportedRace = (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "delayed_fail\n");
const unsupportedRace = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 1_000,
  width: () => 200,
}));
await unsupportedRace.emit("session_start", { reason: "startup" });
await waitFor(async () => {
  const pids = (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean);
  return pids.length > pidsBeforeUnsupportedRace;
}, "delayed failure fixture did not start");
await unsupportedRace.emit("model_select", { model: fixtureModel("custom-proxy", "unsupported-model") });
await waitFor(
  () => unsupportedRace.widgetText(200).includes("unavailable for custom-proxy"),
  "model change did not publish the unsupported-provider view",
);
await sleep(350);
assert(
  unsupportedRace.widgetText(200).includes("unavailable for custom-proxy"),
  `an obsolete process result replaced the unsupported-provider view: ${unsupportedRace.widgetText(200)}`,
);
await unsupportedRace.emit("session_shutdown", { reason: "quit" });

// Timeout and replacement cleanup kill the complete fake process group.
await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
const slow = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 80,
  width: () => 200,
}));
await slow.emit("session_start", { reason: "startup" });
await waitFor(() => slow.widgetText(200).includes("unavailable"), "slow quota process did not time out");
await slow.emit("session_shutdown", { reason: "quit" });

await writeFile(process.env.FM_QUOTA_TEST_MODE, "leader_exit\n");
const leaderExit = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
  width: () => 200,
}));
await leaderExit.emit("session_start", { reason: "startup" });
await waitFor(async () => {
  return Boolean((await readFile(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, "utf8")).trim());
}, "leader-exit fixture did not launch its pipe-holding descendant");
await waitFor(() => leaderExit.widgetText(200).includes("unavailable"), "leader-exit descendant did not time out");
await sleep(1100);
assert(
  !(await readFile(process.env.FM_QUOTA_TEST_SURVIVORS, "utf8")).trim(),
  "quota process-group descendant survived after its leader exited",
);
await leaderExit.emit("session_shutdown", { reason: "quit" });

const descendantsBeforeNormalExit = (await readFile(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
const survivorsBeforeNormalExit = (await readFile(process.env.FM_QUOTA_TEST_SURVIVORS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "leader_exit_closed_stdio\n");
const normalExit = runQuotaAxiJson({ timeoutMs: 500, maxOutputBytes: 1024 * 1024 });
const normalExitResult = await normalExit.promise;
assert(normalExitResult.kind === "ok", `normal-exit descendant fixture failed: ${normalExitResult.kind}`);
const descendantsAfterNormalExit = (await readFile(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
assert(descendantsAfterNormalExit > descendantsBeforeNormalExit, "normal-exit fixture did not launch its descendant");
await sleep(1100);
const survivorsAfterNormalExit = (await readFile(process.env.FM_QUOTA_TEST_SURVIVORS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
assert(survivorsAfterNormalExit === survivorsBeforeNormalExit, "quota descendant survived normal leader completion");

await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
const pidsBeforeReplacement = (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean).length;
const replacement = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 5_000,
  width: () => 240,
}));
await replacement.emit("session_start", { reason: "startup" });
await waitFor(async () => {
  const pids = (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean);
  return pids.length > pidsBeforeReplacement;
}, "replacement fixture did not launch its slow process");
await replacement.emit("session_shutdown", { reason: "new" });
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
replacement.ctx.model = fixtureModel("openai-codex", "replacement-model");
await replacement.emit("session_start", { reason: "new" });
await waitFor(
  () => replacement.widgetText(240).includes("GPT-5.3-Codex-Spark week"),
  "replacement session did not start a fresh quota read",
);
await replacement.emit("session_shutdown", { reason: "quit" });

for (const pid of (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean)) {
  try {
    process.kill(Number(pid), 0);
    throw new Error(`quota process ${pid} survived timeout or replacement cleanup`);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}
assert(process.stdout.listenerCount("resize") === baselineResizeListeners, "final cleanup leaked resize listeners");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "Pi quota status public-interface regression failed: $out"
[ -z "$out" ] || fail "Pi quota status public-interface regression printed output: $out"

[ -s "$CALLS" ] || fail "fake quota-axi was never called"
if grep -Fvx -- '--json' "$CALLS" >/dev/null; then
  fail "quota extension used an unexpected quota-axi argv: $(tr '\n' '|' < "$CALLS")"
fi
if grep -Fvx -- eof "$STDIN_LOG" >/dev/null; then
  fail "quota extension left quota-axi stdin readable: $(tr '\n' '|' < "$STDIN_LOG")"
fi
pass "Pi quota status parses and formats complete active-provider quota, preserves footer statuses in a separate width-aware row, expires reports on time, refreshes every session/model lifecycle, and bounds and cleans fake quota-axi failures"
