#!/usr/bin/env bash
# Portable public-interface regressions for Firstmate's Pi quota status extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi quota status test"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi quota status test"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed @earendil-works/pi-coding-agent package not found"; exit 0; }
[ -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] \
  || { echo "skip: installed Pi package is missing pi-tui"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-pi-quota-status)
FIXTURE="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/quota.calls"
STDIN_LOG="$TMP_ROOT/quota.stdin"
MODE_FILE="$TMP_ROOT/quota.mode"
PID_LOG="$TMP_ROOT/quota.pids"
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
const now = Date.now();
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
export FM_QUOTA_TEST_FIXTURE="$TMP_ROOT/quota-fixture.mjs"
export PATH="$FAKEBIN:$PATH"
printf '%s\n' success > "$MODE_FILE"
: > "$CALLS"
: > "$STDIN_LOG"
: > "$PID_LOG"

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
assert(quotaProviderForPiProvider("openai") === null, "direct OpenAI was incorrectly mapped to Codex quota");

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

function makePi(factory, provider = "openai-codex", mode = "tui") {
  const handlers = new Map();
  const statuses = new Map([["aaa-unrelated", "UNRELATED_STATUS"]]);
  const writes = [];
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
    model: provider ? { provider, id: "fixture-model" } : undefined,
    ui: {
      theme: { fg(_color, text) { return `\x1b[2m${text}\x1b[0m`; } },
      setStatus(key, value) {
        writes.push([key, value]);
        if (value === undefined) statuses.delete(key);
        else statuses.set(key, value);
      },
    },
  };
  async function emit(event, payload = {}, overrideCtx = ctx) {
    for (const handler of handlers.get(event) ?? []) await handler(payload, overrideCtx);
  }
  return { ctx, emit, statuses, writes };
}

const baselineResizeListeners = process.stdout.listenerCount("resize");
const lifecycle = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 80,
  timeoutMs: 500,
  maxOutputBytes: 1024 * 1024,
  width: () => 400,
}));
await lifecycle.emit("session_start", { reason: "startup" });
await waitFor(
  () => plain(lifecycle.statuses.get("zz-firstmate-quota")).includes("GPT-5.3-Codex-Spark week"),
  "startup did not render every Codex quota window",
);
assert(lifecycle.statuses.get("aaa-unrelated") === "UNRELATED_STATUS", "quota status replaced an unrelated extension status");
assert(process.stdout.listenerCount("resize") === baselineResizeListeners + 1, "session start did not own exactly one resize listener");

await lifecycle.emit("model_select", { model: { provider: "anthropic", id: "claude-fixture" } });
await waitFor(
  () => plain(lifecycle.statuses.get("zz-firstmate-quota")).includes("Quota Claude"),
  "model change did not refresh active-provider selection",
);
const callsBeforeCadence = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await sleep(180);
const callsAfterCadence = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterCadence > callsBeforeCadence, "bounded cadence did not refresh during a long-lived session");

await lifecycle.emit("session_shutdown", { reason: "reload" });
assert(!lifecycle.statuses.has("zz-firstmate-quota"), "shutdown did not clear the quota status");
assert(lifecycle.statuses.get("aaa-unrelated") === "UNRELATED_STATUS", "shutdown cleared an unrelated status");
assert(process.stdout.listenerCount("resize") === baselineResizeListeners, "shutdown leaked a resize listener");
const callsAtShutdown = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await sleep(120);
const callsAfterShutdown = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterShutdown === callsAtShutdown, "shutdown leaked a refresh timer");

// Every replacement reason rebinds one generation and refreshes without a process leak.
for (const reason of ["reload", "new", "resume", "fork"]) {
  lifecycle.ctx.model = { provider: "xai", id: "grok-fixture" };
  await lifecycle.emit("session_start", { reason });
  await waitFor(
    () => plain(lifecycle.statuses.get("zz-firstmate-quota")).includes("Quota Grok"),
    `${reason} did not refresh quota status`,
  );
  assert(process.stdout.listenerCount("resize") === baselineResizeListeners + 1, `${reason} duplicated resize listeners`);
  await lifecycle.emit("session_shutdown", { reason: "reload" });
  assert(process.stdout.listenerCount("resize") === baselineResizeListeners, `${reason} leaked resize listeners`);
}

// Non-TUI Pi modes never start status work.
const nonTui = makePi(createFirstmateQuotaStatusExtension({ refreshMs: 40, timeoutMs: 80 }), "openai-codex", "print");
await nonTui.emit("session_start", { reason: "startup" });
assert(!nonTui.statuses.has("zz-firstmate-quota"), "print mode installed a TUI status");
await nonTui.emit("session_shutdown", { reason: "quit" });

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
    () => plain(instance.statuses.get("zz-firstmate-quota")).includes(expected),
    `${mode} did not render ${expected}: ${plain(instance.statuses.get("zz-firstmate-quota"))}`,
  );
  await instance.emit("session_shutdown", { reason: "quit" });
  return instance;
}

await statusCase("malformed", "malformed data");
await statusCase("fail", "unavailable");
await statusCase("stale", "stale");
await statusCase("overflow", "unavailable", { maxOutputBytes: 128 });
await statusCase("success", "unavailable", { command: "quota-axi-definitely-missing" });

// Timeout and replacement cleanup kill the complete fake process group.
await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
const slow = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 80,
  width: () => 200,
}));
await slow.emit("session_start", { reason: "startup" });
await waitFor(() => plain(slow.statuses.get("zz-firstmate-quota")).includes("unavailable"), "slow quota process did not time out");
await slow.emit("session_shutdown", { reason: "quit" });

await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
const replacement = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 5_000,
  width: () => 240,
}));
await replacement.emit("session_start", { reason: "startup" });
await waitFor(async () => {
  const pids = (await readFile(process.env.FM_QUOTA_TEST_PIDS, "utf8")).trim().split(/\s+/).filter(Boolean);
  return pids.length >= 2;
}, "replacement fixture did not launch its slow process");
await replacement.emit("session_shutdown", { reason: "new" });
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
replacement.ctx.model = { provider: "openai-codex", id: "replacement-model" };
await replacement.emit("session_start", { reason: "new" });
await waitFor(
  () => plain(replacement.statuses.get("zz-firstmate-quota")).includes("GPT-5.3-Codex-Spark week"),
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
pass "Pi quota status parses and formats complete active-provider quota, composes through setStatus, degrades explicitly by ANSI-visible width, refreshes on every session/model lifecycle, and bounds and cleans fake quota-axi failures"
