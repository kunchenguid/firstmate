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
PI_CONFIG="$TMP_ROOT/pi-config"
AUTH_FILE="$PI_CONFIG/auth.json"
mkdir -p "$FIXTURE/.pi/extensions/lib" "$FIXTURE/node_modules/@earendil-works" "$FAKEBIN" "$PI_CONFIG"
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
full=0
provider=
if [ "$#" -eq 1 ] && [ "$1" = --json ]; then
  :
elif [ "$#" -eq 4 ] && [ "$1" = --json ] && [ "$2" = --full ] && [ "$3" = --provider ]; then
  full=1
  provider=$4
else
  exit 64
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
    FM_QUOTA_TEST_STALE=1 FM_QUOTA_TEST_FULL=$full FM_QUOTA_TEST_PROVIDER=$provider \
      exec node "${FM_QUOTA_TEST_FIXTURE:?}"
    ;;
  success)
    FM_QUOTA_TEST_FULL=$full FM_QUOTA_TEST_PROVIDER=$provider \
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
const full = process.env.FM_QUOTA_TEST_FULL === "1";
const requestedProvider = process.env.FM_QUOTA_TEST_PROVIDER || "";
const reset = (milliseconds) => new Date(now + milliseconds).toISOString();
const provider = (provider, label, source, fields) => ({
  provider,
  ...fields,
  state: {
    status: "fresh",
    stale: false,
    ...(full ? { refreshedAt: generatedAt, sourcesTried: ["fake"] } : {}),
  },
  ...(full ? { label, source } : {}),
});
const allProviders = [
  provider("claude", "Claude", "oauth", {
    plan: "max",
    windows: [
      { id: "session", label: "session", kind: "session", percentRemaining: 72.5, resetsAt: reset(2 * 60 * 60 * 1000) },
      { id: "week", label: "week", kind: "weekly", percentRemaining: 61, resetsAt: reset(4 * 24 * 60 * 60 * 1000) },
    ],
    credits: { unlimited: true, unit: "credits" },
    ...(full ? { account: { accountId: "fixture-claude-account" } } : {}),
  }),
  provider("codex", "Codex", "oauth", {
    plan: "pro",
    windows: [
      { id: "weekly", label: "week", kind: "weekly", percentRemaining: 94, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
      { id: "model:spark:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", percentRemaining: 100, resetsAt: reset(5 * 60 * 60 * 1000) },
      { id: "model:spark:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", percentRemaining: 100, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
    ],
    credits: { remaining: 0, unlimited: false, unit: "credits" },
    ...(full ? { account: { accountId: "fixture-codex-account" } } : {}),
  }),
  provider("copilot", "GitHub Copilot", "api", {
    plan: "business",
    windows: [],
    ...(full ? { account: { accountId: "fixture-copilot-account" } } : {}),
  }),
  provider("grok", "Grok", "web", {
    windows: [
      { id: "credits", label: "credits", kind: "credits", percentRemaining: 48, resetText: "next month" },
    ],
    ...(full ? {
      account: { email: "fixture@example.invalid" },
      attempts: [
        { source: "web", status: "success" },
        { source: "pi:xai", status: "skipped", error: "model_auth_only", credentialPresent: true },
      ],
    } : {}),
  }),
  provider("kimi", "Kimi", "api", {
    windows: [
      { id: "weekly", label: "week", kind: "weekly", percentRemaining: 83, resetsAt: reset(6 * 24 * 60 * 60 * 1000) },
    ],
    ...(full ? { attempts: [{ source: "pi:kimi-coding", status: "success" }] } : {}),
  }),
];
const providers = requestedProvider
  ? allProviders.filter((entry) => entry.provider === requestedProvider)
  : allProviders;
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
export PI_CODING_AGENT_DIR="$PI_CONFIG"
export PATH="$FAKEBIN:$PATH"
printf '%s\n' '{}' > "$AUTH_FILE"
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
        account: { accountId: "fixture-codex-account" },
        windows: [
          { id: "weekly", label: "week", kind: "weekly", percentRemaining: 94, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString() },
          { id: "spark-session", label: "GPT-5.3-Codex-Spark session", kind: "model", percentRemaining: 100, resetsAt: new Date(now + 5 * 60 * 60 * 1000).toISOString() },
          { id: "spark-week", label: "GPT-5.3-Codex-Spark week", kind: "model", percentRemaining: 100, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString() },
        ],
        credits: { remaining: 0, unlimited: false, unit: "credits" },
        state,
      },
      {
        provider: "kimi",
        label: "Kimi",
        source: "api",
        windows: [
          { id: "weekly", label: "week", kind: "weekly", percentRemaining: 83, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString() },
        ],
        state,
        attempts: [{ source: "pi:kimi-coding", status: "success" }],
      },
    ],
  };
}
function schema5Default(value) {
  const current = structuredClone(value);
  current.schemaVersion = 5;
  for (const provider of current.providers) {
    delete provider.label;
    delete provider.source;
    delete provider.account;
    delete provider.state.refreshedAt;
    delete provider.state.sourcesTried;
  }
  return current;
}

// Parser and formatter public interfaces.
const now = Date.now();
const parsed = parseQuotaAxiJson(JSON.stringify(report(now)));
assert(parsed, "valid quota-axi schema-3 JSON was rejected");
const currentSchema = schema5Default(report(now));
const parsedCurrentSchema = parseQuotaAxiJson(JSON.stringify(currentSchema));
assert(parsedCurrentSchema, "quota-axi schema-5 default JSON was rejected");
const currentCodex = selectActiveProviderQuota(parsedCurrentSchema, "openai-codex", { nowMs: now });
assert(currentCodex.kind === "fresh", `quota-axi schema-5 default provider was not fresh: ${currentCodex.kind}`);
assert(currentCodex.label === "Codex", "schema-5 default provider label was not supplied safely");
const schema5Full = report(now);
schema5Full.schemaVersion = 5;
const parsedSchema5Full = parseQuotaAxiJson(JSON.stringify(schema5Full), { projection: "full" });
assert(parsedSchema5Full, "quota-axi schema-5 full JSON was rejected");
assert(
  selectActiveProviderQuota(parsedSchema5Full, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid quota-axi schema-5 full provider was not fresh",
);
for (const field of ["label", "source"]) {
  const missingFullField = structuredClone(schema5Full);
  delete missingFullField.providers[1][field];
  const missingFullParsed = parseQuotaAxiJson(JSON.stringify(missingFullField), { projection: "full" });
  assert(missingFullParsed, `schema-5 full fixture missing ${field} did not parse structurally`);
  assert(
    selectActiveProviderQuota(missingFullParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-5 full output missing ${field} was accepted as fresh`,
  );
}
const missingFullSources = structuredClone(schema5Full);
delete missingFullSources.providers[1].state.sourcesTried;
const missingFullSourcesParsed = parseQuotaAxiJson(JSON.stringify(missingFullSources), { projection: "full" });
assert(missingFullSourcesParsed, "schema-5 full fixture missing sourcesTried did not parse structurally");
assert(
  selectActiveProviderQuota(missingFullSourcesParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 full output missing sourcesTried was accepted as fresh",
);
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
const matchedAccount = selectActiveProviderQuota(parsed, "openai-codex", {
  nowMs: now,
  expectedAccountId: "fixture-codex-account",
});
assert(matchedAccount.kind === "fresh", "matching active/report account provenance was rejected");
for (const expectedAccountId of [null, "different-account"]) {
  const unverified = selectActiveProviderQuota(parsed, "openai-codex", { nowMs: now, expectedAccountId });
  assert(unverified.kind === "unverified", "unmatched quota account was presented as active quota");
  assert(!formatQuotaStatus(unverified, 200, now).includes("94%"), "unverified account exposed quota percentages");
}
const explicitlyUnverifiedAccount = report(now);
explicitlyUnverifiedAccount.schemaVersion = 5;
explicitlyUnverifiedAccount.providers[1].account.identityStatus = "unverified";
const explicitlyUnverifiedParsed = parseQuotaAxiJson(JSON.stringify(explicitlyUnverifiedAccount));
assert(explicitlyUnverifiedParsed, "explicitly-unverified account fixture did not parse structurally");
assert(
  selectActiveProviderQuota(explicitlyUnverifiedParsed, "openai-codex", {
    nowMs: now,
    expectedAccountId: "fixture-codex-account",
  }).kind === "unverified",
  "explicitly unverified report identity was accepted as active quota",
);
const invalidIdentityStatus = report(now);
invalidIdentityStatus.schemaVersion = 5;
invalidIdentityStatus.providers[1].account.identityStatus = "maybe";
const invalidIdentityParsed = parseQuotaAxiJson(JSON.stringify(invalidIdentityStatus));
assert(invalidIdentityParsed, "invalid-identity fixture did not parse structurally");
assert(
  selectActiveProviderQuota(invalidIdentityParsed, "openai-codex", {
    nowMs: now,
    expectedAccountId: "fixture-codex-account",
  }).kind === "malformed",
  "invalid report identity status was accepted as fresh",
);
const verifiedKimiSource = selectActiveProviderQuota(parsed, "kimi-coding", {
  nowMs: now,
  expectedSuccessfulSource: "pi:kimi-coding",
});
assert(verifiedKimiSource.kind === "fresh", "successful Pi Kimi source was not correlated");
const failedKimiSource = report(now);
failedKimiSource.providers[2].attempts[0].status = "failed";
const failedKimiParsed = parseQuotaAxiJson(JSON.stringify(failedKimiSource));
assert(failedKimiParsed, "failed Kimi source fixture did not parse structurally");
assert(
  selectActiveProviderQuota(failedKimiParsed, "kimi-coding", {
    nowMs: now,
    expectedSuccessfulSource: "pi:kimi-coding",
  }).kind === "unverified",
  "failed Pi Kimi source was accepted as active quota",
);
const invalidKimiAttempt = report(now);
invalidKimiAttempt.providers[2].attempts[0].status = "maybe";
const invalidKimiParsed = parseQuotaAxiJson(JSON.stringify(invalidKimiAttempt));
assert(invalidKimiParsed, "invalid Kimi attempt fixture did not parse structurally");
assert(
  selectActiveProviderQuota(invalidKimiParsed, "kimi-coding", {
    nowMs: now,
    expectedSuccessfulSource: "pi:kimi-coding",
  }).kind === "malformed",
  "invalid Kimi source attempt was accepted as fresh",
);
const paddedAccount = report(now);
paddedAccount.providers[1].account.accountId = " fixture-codex-account ";
const paddedAccountParsed = parseQuotaAxiJson(JSON.stringify(paddedAccount));
assert(paddedAccountParsed, "padded-account fixture did not parse structurally");
assert(
  selectActiveProviderQuota(paddedAccountParsed, "openai-codex", {
    nowMs: now,
    expectedAccountId: "fixture-codex-account",
  }).kind === "unverified",
  "normalized quota account identity was accepted as provenance",
);
const narrow = formatQuotaStatus(codex, 72, now);
assert(narrow.includes("narrow") && narrow.includes("3 windows"), `narrow format was not explicit: ${narrow}`);
assert(!narrow.includes("week 94%"), `narrow format silently presented a partial window set: ${narrow}`);
assert(visibleWidth(narrow) <= 72, "narrow format exceeded its width");
const veryNarrow = formatQuotaStatus(codex, 24, now);
assert(veryNarrow.includes("narrow"), `very narrow format lost its explicit degradation: ${veryNarrow}`);
assert(visibleWidth(veryNarrow) <= 24, "very narrow format exceeded its width");
for (const [reason, expected, compact] of [
  ["missing", "quota-axi missing", "Quota: missing"],
  ["failed", "quota-axi failed", "Quota: failed"],
  ["timeout", "quota-axi timed out", "Quota: timeout"],
  ["overflow", "quota-axi output too large", "Quota: overflow"],
  ["cancelled", "quota refresh cancelled", "Quota: cancelled"],
]) {
  const failureText = formatQuotaStatus({ kind: "failure", provider: "codex", reason }, 200, now);
  assert(failureText.includes(expected), `${reason} failure was not explicit: ${failureText}`);
  const compactFailureText = formatQuotaStatus({ kind: "failure", provider: "codex", reason }, 24, now);
  assert(compactFailureText === compact, `${reason} failure lost its narrow identity: ${compactFailureText}`);
}

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
const resettingRaw = report(now);
resettingRaw.providers[1].windows[0].resetsAt = new Date(now + 60_000).toISOString();
const resettingParsed = parseQuotaAxiJson(JSON.stringify(resettingRaw));
assert(resettingParsed, "reset-expiry fixture did not parse structurally");
const beforeReset = selectActiveProviderQuota(resettingParsed, "openai-codex", { nowMs: now });
assert(beforeReset.kind === "fresh", "quota became stale before its supplied window reset");
assert(beforeReset.freshUntilMs === now + 60_000, "window reset did not bound quota freshness");
const afterReset = selectActiveProviderQuota(resettingParsed, "openai-codex", { nowMs: now + 60_000 });
assert(afterReset.kind === "stale", "post-reset quota percentage remained fresh");
assert(!formatQuotaStatus(afterReset, 200, now + 60_000).includes("94%"), "post-reset quota exposed old percentages");
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
const fullyPopulated = report(now);
const populatedProvider = fullyPopulated.providers[1];
populatedProvider.state.authStatus = "usable";
populatedProvider.state.untrustedWindowIds = [];
Object.assign(populatedProvider.windows[0], {
  percentUsed: 6,
  startsAt: new Date(now - 24 * 60 * 60 * 1000).toISOString(),
  windowSeconds: 7 * 24 * 60 * 60,
  spentUsd: 0,
  limitUsd: 1,
  pace: {
    status: "behind",
    timeRemainingPercent: 85,
    elapsedPercent: 15,
    reservePercentPoints: 9,
    burnMultiple: 0.4,
    projectedExhaustedAt: new Date(now + 7 * 24 * 60 * 60 * 1000).toISOString(),
    projectionConfidence: "established",
    projectionBasis: "cycle_average",
    cycleBasis: "window_seconds",
    cycleSeconds: 7 * 24 * 60 * 60,
  },
});
populatedProvider.quotaSemantics = {
  status: "known",
  description: "Fixture quota semantics",
  effectiveAvailability: [{
    scope: "all_models",
    status: "known",
    effectivePercentRemaining: 94,
    boundedBy: ["weekly"],
    limitingWindowIds: ["weekly"],
    pace: {
      status: "behind",
      behindWindowIds: ["weekly"],
      worstReservePercentPoints: 9,
      worstReserveWindowId: "weekly",
    },
    runway: {
      status: "through_reset",
      projectionConfidence: "established",
      projectionBasis: "cycle_average",
    },
    selection: { status: "known", spendPriority: 1 },
  }],
  unresolvedWindowIds: [],
};
const fullyPopulatedParsed = parseQuotaAxiJson(JSON.stringify(fullyPopulated));
assert(fullyPopulatedParsed, "fully-populated quota fixture did not parse structurally");
assert(
  selectActiveProviderQuota(fullyPopulatedParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid known quota fields were rejected",
);
const invalidPercentUsed = structuredClone(fullyPopulated);
invalidPercentUsed.providers[1].windows[0].percentUsed = "invalid";
const invalidPace = structuredClone(fullyPopulated);
invalidPace.providers[1].windows[0].pace.reservePercentPoints = "invalid";
const invalidQuotaSemantics = structuredClone(fullyPopulated);
invalidQuotaSemantics.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = "invalid";
const invalidAuthStatus = structuredClone(fullyPopulated);
invalidAuthStatus.providers[1].state.authStatus = "invalid";
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
  [invalidPercentUsed, "invalid percent used"],
  [invalidPace, "invalid pace field"],
  [invalidQuotaSemantics, "invalid quota semantics field"],
  [invalidAuthStatus, "invalid auth status"],
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
const directReport = directResult.kind === "ok" ? parseQuotaAxiJson(directResult.stdout) : null;
assert(directReport?.schemaVersion === 5, "fake default quota-axi output did not use schema 5");
assert(
  directReport && selectActiveProviderQuota(directReport, "openai-codex").kind === "fresh",
  "fake default quota-axi projection was not consumable",
);
const grokProcess = runQuotaAxiJson({
  timeoutMs: 1000,
  maxOutputBytes: 1024 * 1024,
  full: true,
  provider: "grok",
});
const grokResult = await grokProcess.promise;
assert(grokResult.kind === "ok", `fake full Grok process failed: ${grokResult.kind}`);
const grokReport = grokResult.kind === "ok"
  ? parseQuotaAxiJson(grokResult.stdout, { projection: "full" })
  : null;
assert(grokReport, "fake full Grok output was not consumable");
assert(
  selectActiveProviderQuota(grokReport, "xai", {
    expectedSuccessfulSource: "pi:xai",
  }).kind === "unverified",
  "model-auth-only Pi xAI attempt was treated as consumer-quota provenance",
);

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
function fixtureAccessToken(accountId) {
  if (!accountId) return "opaque-fixture-token";
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `eyJhbGciOiJub25lIn0.${payload}.fixture`;
}
async function setStoredOAuth(provider, access, expires = Date.now() + 24 * 60 * 60 * 1000) {
  let credentials = {};
  try {
    credentials = JSON.parse(await readFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, "utf8"));
  } catch {
  }
  credentials[provider] = {
    type: "oauth",
    access,
    refresh: `fixture-refresh-${provider}`,
    expires,
  };
  await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, `${JSON.stringify(credentials)}\n`);
}
for (const provider of Object.keys(officialBaseUrls)) {
  await setStoredOAuth(
    provider,
    provider === "openai-codex" ? fixtureAccessToken("fixture-codex-account") : `fixture-${provider}-access`,
  );
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
    modelRegistry: providerOptions.legacyRegistry
      ? {}
      : {
          getProvider() {
            return {
              auth: {
                oauth: {
                  isSubscription: providerOptions.subscription !== false,
                  async toAuth(credential) {
                    if (providerOptions.authNever) return new Promise(() => {});
                    if (providerOptions.authDelayMs) await sleep(providerOptions.authDelayMs);
                    if (providerOptions.authError || providerOptions.authUnavailable) {
                      throw new Error("fixture auth failure");
                    }
                    return {
                      apiKey: credential.access,
                      ...(providerOptions.authBaseUrl ? { baseUrl: providerOptions.authBaseUrl } : {}),
                    };
                  },
                },
              },
            };
          },
          isUsingOAuth() {
            return providerOptions.authType !== "api_key";
          },
          async getProviderAuth() {
            throw new Error("quota extension used the refreshing auth resolver");
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

const callsBeforeClaude = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await lifecycle.emit("model_select", { model: fixtureModel("anthropic", "claude-fixture") });
await waitFor(
  () => lifecycle.widgetText(240).includes("account correlation unavailable"),
  "model change did not classify uncorrelatable Claude quota explicitly",
);
assert(!lifecycle.widgetText(240).includes("72.5%"), "uncorrelated Claude quota was presented as active");
await sleep(30);
const callsAfterClaude = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterClaude === callsBeforeClaude, "uncorrelatable Claude auth invoked quota-axi");
await lifecycle.emit("model_select", { model: fixtureModel("kimi-coding", "kimi-fixture") });
await waitFor(
  () => lifecycle.widgetText(240).includes("week 83% left"),
  "model change did not correlate the active Pi Kimi source",
);
assert(!lifecycle.widgetText(240).includes("account unverified"), "active Pi Kimi quota remained unverified");
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

const transitionOptions = {};
const resolvingTransition = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
  "tui",
  transitionOptions,
);
await resolvingTransition.emit("session_start", { reason: "startup" });
await waitFor(
  () => resolvingTransition.widgetText(400).includes("week 94% left"),
  "transition fixture did not publish its initial official quota",
);
transitionOptions.authDelayMs = 150;
await resolvingTransition.emit("model_select", {
  model: fixtureModel("openai-codex", "custom-codex", "https://proxy.example.invalid"),
});
assert(
  resolvingTransition.widgetText(400).includes("refreshing"),
  `unresolved model target did not render explicitly: ${resolvingTransition.widgetText(400)}`,
);
assert(
  !resolvingTransition.widgetText(400).includes("94%"),
  "unresolved custom-endpoint model reused cached official quota",
);
await waitFor(
  () => resolvingTransition.widgetText(400).includes("custom endpoint"),
  "custom-endpoint model did not resolve to unavailable",
);
await resolvingTransition.emit("session_shutdown", { reason: "quit" });

const authTimeout = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 40 }),
  "openai-codex",
  "tui",
  { authDelayMs: 200 },
);
await authTimeout.emit("session_start", { reason: "startup" });
await waitFor(
  () => authTimeout.widgetText(240).includes("auth timed out"),
  `stalled auth resolution did not time out explicitly: ${authTimeout.widgetText(240)}`,
);
await authTimeout.emit("session_shutdown", { reason: "quit" });

const stalledAuthOptions = { authNever: true };
const stalledAuth = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 5_000 }),
  "openai-codex",
  "tui",
  stalledAuthOptions,
);
await stalledAuth.emit("session_start", { reason: "startup" });
assert(stalledAuth.widgetText(240).includes("refreshing"), "stalled auth did not retain a bounded pending view");
await stalledAuth.emit("session_shutdown", { reason: "reload" });
stalledAuthOptions.authNever = false;
await stalledAuth.emit("session_start", { reason: "reload" });
await waitFor(
  () => stalledAuth.widgetText(400).includes("week 94% left"),
  "shutdown did not cancel stalled auth before replacement startup",
);
await stalledAuth.emit("session_shutdown", { reason: "quit" });

await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));
const credentialChange = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await credentialChange.emit("session_start", { reason: "startup" });
await waitFor(
  () => credentialChange.widgetText(400).includes("week 94% left"),
  "credential-change fixture did not publish initial account quota",
);
await setStoredOAuth("openai-codex", fixtureAccessToken("replacement-codex-account"));
assert(
  !credentialChange.widgetText(400).includes("94%"),
  "credential change remained fresh at the render boundary",
);
await waitFor(
  () => credentialChange.widgetText(240).includes("account unverified"),
  `credential change was not re-correlated: ${credentialChange.widgetText(240)}`,
);
await credentialChange.emit("session_shutdown", { reason: "quit" });
const writesAfterCredentialShutdown = credentialChange.widgetWriteCount;
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));
await sleep(100);
assert(
  credentialChange.widgetWriteCount === writesAfterCredentialShutdown,
  "shutdown leaked the credential watcher",
);

for (const reason of ["reload", "new", "resume", "fork"]) {
  lifecycle.ctx.model = fixtureModel("kimi-coding", "kimi-fixture");
  await lifecycle.emit("session_start", { reason });
  await waitFor(
    () => lifecycle.widgetText(240).includes("week 83% left"),
    `${reason} did not correlate the active Pi Kimi source`,
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
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  fakeStart + 4 * 60 * 1000,
);
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
fakeClock.jump(-2 * 60 * 1000);
assert(expiring.widgetText(400).includes("stale"), "backward clock shift did not revalidate report freshness");
assert(!expiring.widgetText(400).includes("94%"), "backward clock shift exposed future-dated quota as fresh");
fakeClock.jump(2 * 60 * 1000);
assert(expiring.widgetText(400).includes("week 94% left"), "restored clock did not recover valid fresh quota");
await writeFile(process.env.FM_QUOTA_TEST_MODE, "fail\n");
const writesBeforeFailedRefresh = expiring.widgetWriteCount;
fakeClock.advance(5 * 60 * 1000);
await waitFor(
  () => expiring.widgetText(400).includes("quota-axi failed"),
  `failed refresh did not expose its outcome beside cached quota: ${expiring.widgetText(400)}`,
);
assert(expiring.widgetWriteCount > writesBeforeFailedRefresh, "failed refresh did not republish the still-fresh report");
assert(!expiring.widgetText(400).includes("auth expired"), "soft OAuth expiry was classified as unsupported");
assert(expiring.widgetText(400).includes("week 94% left"), "failed refresh discarded quota before its freshness deadline");
const writesBeforeDelayedExpiry = expiring.widgetWriteCount;
fakeClock.jump(60 * 1000);
assert(expiring.widgetWriteCount === writesBeforeDelayedExpiry, "fake clock unexpectedly ran the delayed expiry callback");
assert(expiring.widgetText(400).includes("quota-axi failed"), "expired cached quota hid the latest refresh failure");
assert(!expiring.widgetText(400).includes("94%"), "rendering presented expired quota values as fresh");
fakeClock.advance(0);
assert(expiring.widgetWriteCount > writesBeforeDelayedExpiry, "expiry callback did not republish the failed refresh view");
await expiring.emit("session_shutdown", { reason: "quit" });
assert(fakeClock.tasks.size === 0, "shutdown leaked a fake-clock refresh or expiry timer");
delete process.env.FM_QUOTA_TEST_NOW_MS;
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));

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

await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const callsBeforeXai = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const uncorrelatableXai = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 100 }),
  "xai",
);
await uncorrelatableXai.emit("session_start", { reason: "startup" });
await waitFor(
  () => uncorrelatableXai.widgetText(240).includes("account correlation unavailable"),
  `Pi xAI consumer quota was not classified explicitly: ${uncorrelatableXai.widgetText(240)}`,
);
await sleep(30);
const callsAfterXai = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterXai === callsBeforeXai, "uncorrelatable Pi xAI auth invoked quota-axi");
await uncorrelatableXai.emit("session_shutdown", { reason: "quit" });

const callsBeforeLegacyRegistry = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const legacyRegistry = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 100 }),
  "openai-codex",
  "tui",
  { legacyRegistry: true },
);
await legacyRegistry.emit("session_start", { reason: "startup" });
assert(
  legacyRegistry.widgetText(240).includes("auth inspection unavailable"),
  `older Pi registry was not handled explicitly: ${legacyRegistry.widgetText(240)}`,
);
await sleep(30);
const callsAfterLegacyRegistry = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterLegacyRegistry === callsBeforeLegacyRegistry, "older Pi registry invoked quota-axi without auth inspection");
await legacyRegistry.emit("session_shutdown", { reason: "quit" });

for (const endpoint of [
  "https://api.business.githubcopilot.com",
  "https://api.enterprise.githubcopilot.com",
]) {
  const callsBefore = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
  const instance = makePi(
    createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
    "github-copilot",
    "tui",
    { authBaseUrl: endpoint },
  );
  await instance.emit("session_start", { reason: "startup" });
  await waitFor(
    () => instance.widgetText(240).includes("account correlation unavailable"),
    `official Copilot endpoint did not report unverifiable provenance: ${endpoint}: ${instance.widgetText(240)}`,
  );
  const callsAfter = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
  assert(callsAfter === callsBefore, `uncorrelatable Copilot auth invoked quota-axi: ${endpoint}`);
  await instance.emit("session_shutdown", { reason: "quit" });
}

const callsBeforeEnterpriseProxy = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const enterpriseProxy = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 100 }),
  "github-copilot",
  "tui",
  { authBaseUrl: "https://copilot-api.company.ghe.example" },
);
await enterpriseProxy.emit("session_start", { reason: "startup" });
await waitFor(
  () => enterpriseProxy.widgetText(240).includes("custom endpoint"),
  `custom Copilot proxy was not rejected: ${enterpriseProxy.widgetText(240)}`,
);
await sleep(30);
const callsAfterEnterpriseProxy = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterEnterpriseProxy === callsBeforeEnterpriseProxy, "custom Copilot proxy invoked quota-axi");
await enterpriseProxy.emit("session_shutdown", { reason: "quit" });

for (const [description, accountId] of [
  ["missing active account identity", null],
  ["different active account", "other-codex-account"],
]) {
  await setStoredOAuth("openai-codex", fixtureAccessToken(accountId));
  const instance = makePi(
    createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
    "openai-codex",
  );
  await instance.emit("session_start", { reason: "startup" });
  await waitFor(
    () => instance.widgetText(240).includes("account unverified"),
    `${description} was not refused: ${instance.widgetText(240)}`,
  );
  assert(!instance.widgetText(400).includes("94%"), `${description} exposed unrelated fresh quota`);
  await instance.emit("session_shutdown", { reason: "quit" });
}
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));

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
await statusCase("fail", "quota-axi failed");
await statusCase("stale", "stale");
await statusCase("overflow", "quota-axi output too large", { maxOutputBytes: 128 });
await statusCase("success", "quota-axi missing", { command: "quota-axi-definitely-missing" });
await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
const cancelledProcess = runQuotaAxiJson({ timeoutMs: 5_000, maxOutputBytes: 1024 * 1024 });
cancelledProcess.cancel();
assert((await cancelledProcess.promise).kind === "cancelled", "quota process cancellation lost its reason");

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
await waitFor(() => slow.widgetText(200).includes("quota-axi timed out"), "slow quota process did not time out explicitly");
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
await waitFor(() => leaderExit.widgetText(200).includes("quota-axi timed out"), "leader-exit descendant did not time out explicitly");
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
if grep -Ev -- '^(--json|--json --full --provider (claude|codex|copilot|grok|kimi))$' "$CALLS" >/dev/null; then
  fail "quota extension used an unexpected quota-axi argv: $(tr '\n' '|' < "$CALLS")"
fi
if grep -Fvx -- eof "$STDIN_LOG" >/dev/null; then
  fail "quota extension left quota-axi stdin readable: $(tr '\n' '|' < "$STDIN_LOG")"
fi
pass "Pi quota status parses real schema projections, correlates active accounts and official endpoints, preserves footer composition, expires reports, refreshes lifecycle transitions, and bounds and cleans fake quota-axi failures"
