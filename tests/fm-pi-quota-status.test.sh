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
TASKKILL_LOG="$TMP_ROOT/taskkill.calls"
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
  structured_timeout)
    FM_QUOTA_TEST_FAILURE='Codex quota request timed out' \
      FM_QUOTA_TEST_FULL=$full FM_QUOTA_TEST_PROVIDER=$provider \
      node "${FM_QUOTA_TEST_FIXTURE:?}"
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
    descendants_before=$(wc -l < "${FM_QUOTA_TEST_DESCENDANT_PIDS:?}")
    node -e '
      const fs = require("node:fs");
      fs.appendFileSync(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, `${process.pid}\n`);
      setTimeout(() => {
        fs.appendFileSync(process.env.FM_QUOTA_TEST_SURVIVORS, `${process.pid}\n`);
      }, 1000);
    ' &
    while [ "$(wc -l < "${FM_QUOTA_TEST_DESCENDANT_PIDS:?}")" -le "$descendants_before" ]; do
      sleep 0.01
    done
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
  stale_timeout)
    FM_QUOTA_TEST_STALE_FAILURE='Codex quota request timed out' \
      FM_QUOTA_TEST_FULL=$full FM_QUOTA_TEST_PROVIDER=$provider \
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

cat > "$FAKEBIN/taskkill" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_QUOTA_TEST_TASKKILL_CALLS:?}"
pid=
while [ "$#" -gt 0 ]; do
  if [ "$1" = /PID ] && [ "$#" -gt 1 ]; then
    shift
    pid=$1
  fi
  shift
done
[ -n "$pid" ] || exit 2
kill -0 "$pid" 2>/dev/null || exit 3
delay=${FM_QUOTA_TEST_TASKKILL_DELAY_SECONDS:-0}
[ "$delay" = 0 ] || sleep "$delay"
kill -TERM "$pid" 2>/dev/null || exit 3
attempt=0
while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
  sleep 0.01
  attempt=$((attempt + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid" 2>/dev/null || true
fi
exit 0
SH

cat > "$FAKEBIN/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
exec node "${FM_QUOTA_TEST_WINDOWS_SUPERVISOR:?}"
SH
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/taskkill" "$FAKEBIN/powershell.exe"

cat > "$TMP_ROOT/windows-job-supervisor.mjs" <<'JS'
import { spawn } from "node:child_process";

const payload = JSON.parse(Buffer.from(process.env.FM_QUOTA_JOB_PAYLOAD, "base64").toString("utf8"));
const child = spawn(payload.command, payload.arguments, {
  detached: true,
  shell: false,
  stdio: ["ignore", "inherit", "inherit"],
});
let settled = false;
const finish = (code) => {
  if (settled) return;
  settled = true;
  if (child.pid) {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
    }
  }
  setTimeout(() => process.exit(code), 10);
};
child.on("error", (error) => finish(error.code === "ENOENT" ? 127 : 126));
child.on("exit", (code) => finish(code ?? 126));
process.on("SIGTERM", () => finish(143));
process.on("SIGINT", () => finish(130));
JS

cat > "$TMP_ROOT/quota-fixture.mjs" <<'JS'
const configuredNow = Number(process.env.FM_QUOTA_TEST_NOW_MS);
const now = Number.isFinite(configuredNow) && configuredNow > 0 ? configuredNow : Date.now();
const generatedAt = new Date(now - (process.env.FM_QUOTA_TEST_STALE === "1" ? 60 * 60 * 1000 : 0)).toISOString();
const full = process.env.FM_QUOTA_TEST_FULL === "1";
const requestedProvider = process.env.FM_QUOTA_TEST_PROVIDER || "";
const reset = (milliseconds) => new Date(now + milliseconds).toISOString();
const configuredCodexReset = Number(process.env.FM_QUOTA_TEST_FIRST_RESET_MS);
const codexFirstResetMs = Number.isFinite(configuredCodexReset) && configuredCodexReset > 0
  ? configuredCodexReset
  : 6 * 24 * 60 * 60 * 1000;
const round = (value) => Number(value.toFixed(4));
const withPace = (window) => {
  const startsAtMs = Date.parse(window.startsAt);
  const resetsAtMs = Date.parse(window.resetsAt);
  const cycleSeconds = (resetsAtMs - startsAtMs) / 1000;
  const elapsedPercent = 100 * (now - startsAtMs) / (cycleSeconds * 1000);
  const timeRemainingPercent = 100 * (resetsAtMs - now) / (cycleSeconds * 1000);
  const percentUsed = window.percentUsed ?? 100 - window.percentRemaining;
  const reservePercentPoints = window.percentRemaining - timeRemainingPercent;
  const pace = {
    status: Math.abs(reservePercentPoints) <= 1
      ? "on_pace"
      : reservePercentPoints < 0 ? "ahead" : "behind",
    timeRemainingPercent: round(timeRemainingPercent),
    elapsedPercent: round(elapsedPercent),
    reservePercentPoints: round(reservePercentPoints),
    cycleBasis: "starts_at_resets_at",
    cycleSeconds,
  };
  if (elapsedPercent > 0) pace.burnMultiple = round(percentUsed / elapsedPercent);
  if (percentUsed > 0 && now > startsAtMs) {
    pace.projectedExhaustedAt = new Date(
      now + window.percentRemaining / (percentUsed / (now - startsAtMs)),
    ).toISOString();
    pace.projectionConfidence = elapsedPercent < 10 ? "early" : "established";
  }
  return { ...window, percentUsed, pace };
};
const effectiveAvailability = (scope, windows) => {
  const boundedBy = windows.map(({ id }) => id);
  const effectivePercentRemaining = Math.min(...windows.map(({ percentRemaining }) => percentRemaining));
  const limitingWindowIds = windows
    .filter(({ percentRemaining }) => percentRemaining === effectivePercentRemaining)
    .map(({ id }) => id);
  const paceGroups = { ahead: [], behind: [], on_pace: [], unknown: [] };
  for (const window of windows) paceGroups[window.pace.status].push(window.id);
  const reserves = windows
    .filter((window) => window.pace.reservePercentPoints !== undefined)
    .sort((left, right) => left.pace.reservePercentPoints - right.pace.reservePercentPoints);
  const pace = {
    status: paceGroups.ahead.length > 0 && paceGroups.behind.length > 0
      ? "mixed"
      : paceGroups.ahead.length > 0
        ? "ahead"
        : paceGroups.behind.length > 0 ? "behind" : "on_pace",
    ...(paceGroups.ahead.length ? { aheadWindowIds: paceGroups.ahead } : {}),
    ...(paceGroups.behind.length ? { behindWindowIds: paceGroups.behind } : {}),
    ...(paceGroups.on_pace.length ? { onPaceWindowIds: paceGroups.on_pace } : {}),
    ...(paceGroups.unknown.length ? { unknownWindowIds: paceGroups.unknown } : {}),
    worstReservePercentPoints: reserves[0].pace.reservePercentPoints,
    worstReserveWindowId: reserves[0].id,
  };
  const projected = windows
    .filter((window) => window.pace.projectedExhaustedAt)
    .map((window) => ({ window, at: Date.parse(window.pace.projectedExhaustedAt) }))
    .filter(({ window, at }) => at < Date.parse(window.resetsAt))
    .sort((left, right) => left.at - right.at);
  const runway = projected.length
    ? {
        status: "projected_exhaustion",
        usableRunwaySeconds: Math.max(0, Math.round((projected[0].at - now) / 1000)),
        projectedExhaustedAt: new Date(projected[0].at).toISOString(),
        limitingWindowId: projected[0].window.id,
        projectionConfidence: projected[0].window.pace.projectionConfidence,
      }
    : {
        status: "through_reset",
        projectionConfidence: windows.some((window) => (
          window.pace.projectionConfidence === "early" || window.pace.elapsedPercent < 10
        )) ? "early" : "established",
      };
  let weightedGapSum = 0;
  let cycleSecondsSum = 0;
  for (const window of windows) {
    const burnMultiple = window.pace.burnMultiple ?? 0;
    const gap = window.percentRemaining / window.pace.timeRemainingPercent - burnMultiple;
    weightedGapSum += gap * window.pace.cycleSeconds;
    cycleSecondsSum += window.pace.cycleSeconds;
  }
  return {
    scope,
    status: "known",
    effectivePercentRemaining,
    boundedBy,
    limitingWindowIds,
    pace,
    runway,
    selection: {
      status: "known",
      spendPriority: round(Math.min(100, Math.max(-100, weightedGapSum / cycleSecondsSum))),
    },
  };
};
const provider = (provider, label, source, fields) => ({
  provider,
  label,
  source,
  ...fields,
  state: {
    status: "fresh",
    stale: false,
    refreshedAt: generatedAt,
    sourcesTried: fields.attempts.map(({ source: attemptedSource }) => attemptedSource),
  },
});
const codexWindows = [
  withPace({
    id: "weekly",
    label: "week",
    kind: "weekly",
    percentUsed: 6,
    percentRemaining: 94,
    startsAt: new Date(now - 24 * 60 * 60 * 1000).toISOString(),
    resetsAt: reset(codexFirstResetMs),
  }),
  withPace({
    id: "model:spark:5h",
    label: "GPT-5.3-Codex-Spark session",
    kind: "model",
    percentUsed: 0,
    percentRemaining: 100,
    startsAt: generatedAt,
    resetsAt: reset(5 * 60 * 60 * 1000),
  }),
  withPace({
    id: "model:spark:7d",
    label: "GPT-5.3-Codex-Spark week",
    kind: "model",
    percentUsed: 0,
    percentRemaining: 100,
    startsAt: generatedAt,
    resetsAt: reset(6 * 24 * 60 * 60 * 1000),
  }),
];
const claudeWindows = [
  withPace({
    id: "five_hour",
    label: "session",
    kind: "session",
    percentRemaining: 72.5,
    startsAt: new Date(now - 3 * 60 * 60 * 1000).toISOString(),
    resetsAt: reset(2 * 60 * 60 * 1000),
  }),
  withPace({
    id: "seven_day",
    label: "week",
    kind: "weekly",
    percentRemaining: 61,
    startsAt: new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString(),
    resetsAt: reset(4 * 24 * 60 * 60 * 1000),
  }),
];
const grokWindows = [
  withPace({
    id: "credits",
    label: "credits",
    kind: "credits",
    percentRemaining: 48,
    startsAt: new Date(now - 15 * 24 * 60 * 60 * 1000).toISOString(),
    resetsAt: reset(15 * 24 * 60 * 60 * 1000),
  }),
];
const kimiWindows = [
  withPace({
    id: "weekly",
    label: "week",
    kind: "weekly",
    percentRemaining: 83,
    startsAt: new Date(now - 24 * 60 * 60 * 1000).toISOString(),
    resetsAt: reset(6 * 24 * 60 * 60 * 1000),
  }),
];
const allProviders = [
  provider("claude", "Claude", "oauth", {
    plan: "max",
    windows: claudeWindows,
    quotaSemantics: {
      status: "known",
      description: "Claude account windows bound every model.",
      effectiveAvailability: [effectiveAvailability("all_models", claudeWindows)],
    },
    credits: { unlimited: true, unit: "credits" },
    account: { accountId: "fixture-claude-account" },
    attempts: [
      { source: "oauth-file", status: "success" },
      { source: "oauth-profile", status: "success" },
    ],
  }),
  provider("codex", "Codex", "oauth", {
    plan: "pro",
    windows: codexWindows,
    quotaSemantics: {
      status: "known",
      description: "Codex base account windows bound every model. Named model windows add bounds for that model; code-review windows describe a separate workload and are not included in model availability.",
      effectiveAvailability: [
        effectiveAvailability("all_models", [codexWindows[0]]),
        effectiveAvailability("model:spark", codexWindows),
      ],
    },
    credits: { remaining: 0, unlimited: false, unit: "credits" },
    account: {
      accountId: process.env.FM_QUOTA_TEST_CODEX_ACCOUNT_ID || "fixture-codex-account",
    },
    attempts: [{ source: "oauth", status: "success" }],
  }),
  provider("copilot", "GitHub Copilot", "api", {
    plan: "business",
    windows: [],
    quotaSemantics: {
      status: "unknown",
      description: "No quota windows are available.",
      effectiveAvailability: [],
      unresolvedWindowIds: [],
    },
    account: { accountId: "fixture-copilot-account" },
    attempts: [{ source: "api", status: "success" }],
  }),
  provider("grok", "Grok", "web", {
    windows: grokWindows,
    quotaSemantics: {
      status: "known",
      description: "Grok shared credits bind every product.",
      effectiveAvailability: [effectiveAvailability("all_products", grokWindows)],
    },
    account: { email: "fixture@example.invalid" },
    attempts: [
      { source: "web", status: "success" },
      { source: "pi:xai", status: "skipped", error: "model_auth_only", credentialPresent: true },
    ],
  }),
  provider("kimi", "Kimi", "api", {
    windows: kimiWindows,
    quotaSemantics: {
      status: "known",
      description: "Kimi account windows jointly bind every model.",
      effectiveAvailability: [effectiveAvailability("all_models", kimiWindows)],
    },
    attempts: [{ source: "pi:kimi-coding", status: "success" }],
  }),
];
const demoteWindow = (window) => ({
  ...window,
  percentUsed: undefined,
  startsAt: undefined,
  windowSeconds: undefined,
  ...(window.pace ? {
    pace: {
      status: window.pace.status,
      ...(window.pace.reason ? { reason: window.pace.reason } : {}),
      reservePercentPoints: window.pace.reservePercentPoints,
      burnMultiple: window.pace.burnMultiple,
    },
  } : {}),
});
const demoteProvider = (entry) => ({
  ...entry,
  label: undefined,
  source: undefined,
  account: undefined,
  attempts: undefined,
  windows: entry.windows.map(demoteWindow),
  ...(entry.quotaSemantics ? {
    quotaSemantics: {
      ...entry.quotaSemantics,
      description: undefined,
      effectiveAvailability: entry.quotaSemantics.effectiveAvailability.map((availability) => ({
        ...availability,
        ...(availability.pace ? {
          pace: {
            ...availability.pace,
            behindWindowIds: undefined,
            onPaceWindowIds: undefined,
          },
        } : {}),
      })),
    },
  } : {}),
  state: { ...entry.state, refreshedAt: undefined, sourcesTried: undefined },
});
const projectedProviders = full ? allProviders : allProviders.map(demoteProvider);
const providers = requestedProvider
  ? projectedProviders.filter((entry) => entry.provider === requestedProvider)
  : projectedProviders;
if (process.env.FM_QUOTA_TEST_FAILURE) {
  for (const entry of providers) {
    entry.source = "unavailable";
    entry.windows = [];
    entry.quotaSemantics = {
      status: "unknown",
      description: "No quota windows are available.",
      effectiveAvailability: [],
    };
    entry.attempts = entry.provider === "codex"
      ? [
          { source: "oauth", status: "failed", error: process.env.FM_QUOTA_TEST_FAILURE },
          { source: "cli-rpc", status: "failed", error: process.env.FM_QUOTA_TEST_FAILURE },
        ]
      : entry.attempts.map((attempt) => ({
          source: attempt.source,
          status: "failed",
          error: process.env.FM_QUOTA_TEST_FAILURE,
        }));
    entry.state = {
      status: "error",
      stale: false,
      error: process.env.FM_QUOTA_TEST_FAILURE,
      sourcesTried: entry.attempts.map(({ source }) => source),
    };
  }
}
if (process.env.FM_QUOTA_TEST_STALE_FAILURE) {
  for (const entry of providers) {
    const staleFailure = process.env.FM_QUOTA_TEST_STALE_FAILURE;
    const semantics = entry.quotaSemantics;
    entry.source = "cache";
    entry.windows = entry.windows.map((window) => ({
      ...window,
      pace: { status: "unknown", reason: "stale" },
    }));
    entry.quotaSemantics = {
      status: semantics.status === "partial" ? "partial" : "unknown",
      description: "Cached quota windows are stale diagnostics.",
      effectiveAvailability: semantics.effectiveAvailability.map(({ scope, boundedBy }) => ({
        scope,
        status: "unknown",
        boundedBy,
        pace: { status: "unknown", unknownWindowIds: boundedBy },
        runway: { status: "unknown", unmeasurableWindowIds: boundedBy },
        selection: { status: "unknown", unmeasurableWindowIds: boundedBy },
      })),
      ...(semantics.unresolvedWindowIds
        ? { unresolvedWindowIds: semantics.unresolvedWindowIds }
        : {}),
    };
    entry.attempts = entry.provider === "codex"
      ? [
          { source: "oauth", status: "failed", error: staleFailure },
          { source: "cli-rpc", status: "failed", error: staleFailure },
        ]
      : entry.attempts.map((attempt) => ({
          source: attempt.source,
          status: "failed",
          error: staleFailure,
        }));
    entry.state = {
      status: "stale",
      stale: true,
      refreshedAt: process.env.FM_QUOTA_TEST_STALE_REFRESHED_AT || entry.state.refreshedAt,
      error: staleFailure,
      sourcesTried: [...new Set([...entry.attempts.map(({ source }) => source), "cache"])],
    };
  }
}
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
export FM_QUOTA_TEST_TASKKILL_CALLS="$TASKKILL_LOG"
export FM_QUOTA_TEST_FIXTURE="$TMP_ROOT/quota-fixture.mjs"
export FM_QUOTA_TEST_WINDOWS_SUPERVISOR="$TMP_ROOT/windows-job-supervisor.mjs"
export PI_CODING_AGENT_DIR="$PI_CONFIG"
export PATH="$FAKEBIN:$PATH"
printf '%s\n' '{}' > "$AUTH_FILE"
printf '%s\n' success > "$MODE_FILE"
: > "$CALLS"
: > "$STDIN_LOG"
: > "$PID_LOG"
: > "$DESCENDANT_PID_LOG"
: > "$SURVIVOR_LOG"
: > "$TASKKILL_LOG"

out=$(cd "$FIXTURE" && \
  EXT="$FIXTURE/.pi/extensions/fm-pi-quota-status.ts" \
  LIB="$FIXTURE/.pi/extensions/lib/fm-pi-quota-status.ts" \
  node --input-type=module 2>&1 <<'JS'
import fs from "node:fs";
import { EventEmitter } from "node:events";
import { syncBuiltinESMExports } from "node:module";
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
  createQuotaStatusFormatter,
  formatQuotaStatus,
  parseQuotaAxiJson,
  quotaProviderForPiProvider,
  revalidateFreshQuotaView,
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
  const state = (sourcesTried) => ({
    status: "fresh",
    stale: false,
    refreshedAt: new Date(now).toISOString(),
    sourcesTried,
  });
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
          { id: "session", label: "session", kind: "session", percentRemaining: 72.5, resetsAt: new Date(now + 2 * 60 * 60 * 1000).toISOString(), pace: { status: "unknown", reason: "missing_cycle" } },
        ],
        credits: { unlimited: true, unit: "credits" },
        state: state(["oauth-file", "oauth-profile"]),
        attempts: [
          { source: "oauth-file", status: "success" },
          { source: "oauth-profile", status: "success" },
        ],
      },
      {
        provider: "codex",
        label: "Codex",
        source: "oauth",
        plan: "pro",
        account: { accountId: "fixture-codex-account" },
        windows: [
          { id: "weekly", label: "week", kind: "weekly", percentUsed: 6, percentRemaining: 94, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString(), pace: { status: "unknown", reason: "missing_cycle" } },
          { id: "model:spark:5h", label: "GPT-5.3-Codex-Spark session", kind: "model", percentUsed: 0, percentRemaining: 100, resetsAt: new Date(now + 5 * 60 * 60 * 1000).toISOString(), pace: { status: "unknown", reason: "missing_cycle" } },
          { id: "model:spark:7d", label: "GPT-5.3-Codex-Spark week", kind: "model", percentUsed: 0, percentRemaining: 100, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString(), pace: { status: "unknown", reason: "missing_cycle" } },
        ],
        credits: { remaining: 0, unlimited: false, unit: "credits" },
        state: state(["oauth"]),
        attempts: [{ source: "oauth", status: "success" }],
      },
      {
        provider: "kimi",
        label: "Kimi",
        source: "api",
        windows: [
          { id: "weekly", label: "week", kind: "weekly", percentRemaining: 83, resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString(), pace: { status: "unknown", reason: "missing_cycle" } },
        ],
        state: state(["pi:kimi-coding"]),
        attempts: [{ source: "pi:kimi-coding", status: "success" }],
      },
    ],
  };
}
function schema5CodexSemantics(value, full) {
  const codex = value.providers.find((provider) => provider.provider === "codex");
  for (const window of codex.windows) {
    window.pace = { status: "unknown", reason: "missing_cycle" };
  }
  const account = codex.windows.filter((window) => /^(?:five_hour|weekly)(?:_\d+)?$/.test(window.id));
  const models = new Map();
  for (const window of codex.windows.filter((candidate) => candidate.kind === "model")) {
    const scope = window.id.replace(/_\d+$/, "").replace(/:(?:5h|7d|window:[^:]+)$/, "");
    models.set(scope, [...(models.get(scope) ?? []), window]);
  }
  const availability = (scope, windows) => {
    const boundedBy = windows.map((window) => window.id);
    const effectivePercentRemaining = Math.min(...windows.map((window) => window.percentRemaining));
    return {
      scope,
      status: "known",
      effectivePercentRemaining,
      boundedBy,
      limitingWindowIds: windows
        .filter((window) => window.percentRemaining === effectivePercentRemaining)
        .map((window) => window.id),
      pace: { status: "unknown", unknownWindowIds: boundedBy },
      runway: { status: "unknown", unmeasurableWindowIds: boundedBy },
      selection: { status: "unknown", unmeasurableWindowIds: boundedBy },
    };
  };
  return {
    status: "known",
    ...(full ? { description: "Codex base account windows bound every model." } : {}),
    effectiveAvailability: [
      ...(account.length > 0 ? [availability("all_models", account)] : []),
      ...[...models].map(([scope, windows]) => availability(scope, [...account, ...windows])),
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
    delete provider.attempts;
    delete provider.state.refreshedAt;
    delete provider.state.sourcesTried;
    for (const window of provider.windows) delete window.percentUsed;
  }
  current.providers.find((provider) => provider.provider === "codex").quotaSemantics =
    schema5CodexSemantics(current, false);
  return current;
}

// Parser and formatter public interfaces.
const now = Date.now();
const parsed = parseQuotaAxiJson(JSON.stringify(report(now)));
assert(parsed, "valid quota-axi schema-3 JSON was rejected");
for (const generatedAt of [
  "2026-08-20T12:00:00.000",
  "2026-02-30T12:00:00.000Z",
]) {
  const invalidTimestampReport = report(now);
  invalidTimestampReport.generatedAt = generatedAt;
  assert(
    parseQuotaAxiJson(JSON.stringify(invalidTimestampReport)) === null,
    `noncanonical generatedAt ${generatedAt} was accepted`,
  );
}
const currentSchema = schema5Default(report(now));
const parsedCurrentSchema = parseQuotaAxiJson(JSON.stringify(currentSchema));
assert(parsedCurrentSchema, "quota-axi schema-5 default JSON was rejected");
const currentCodex = selectActiveProviderQuota(parsedCurrentSchema, "openai-codex", { nowMs: now });
assert(currentCodex.kind === "fresh", `quota-axi schema-5 default provider was not fresh: ${currentCodex.kind}`);
assert(currentCodex.label === "Codex", "schema-5 default provider label was not supplied safely");
const schema5Full = report(now);
schema5Full.schemaVersion = 5;
schema5Full.providers[1].quotaSemantics = schema5CodexSemantics(schema5Full, true);
const parsedSchema5Full = parseQuotaAxiJson(JSON.stringify(schema5Full), { projection: "full" });
assert(parsedSchema5Full, "quota-axi schema-5 full JSON was rejected");
assert(
  selectActiveProviderQuota(parsedSchema5Full, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid quota-axi schema-5 full provider was not fresh",
);
for (const resetsAt of [
  schema5Full.providers[1].windows[0].resetsAt.slice(0, -1),
  "2026-02-30T12:00:00.000Z",
]) {
  const invalidWindowTimestamp = structuredClone(schema5Full);
  invalidWindowTimestamp.providers[1].windows[0].resetsAt = resetsAt;
  const invalidWindowTimestampParsed = parseQuotaAxiJson(
    JSON.stringify(invalidWindowTimestamp),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(invalidWindowTimestampParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `noncanonical window timestamp ${resetsAt} was accepted as fresh`,
  );
}
for (const [projection, schema5Report] of [
  ["default", currentSchema],
  ["full", schema5Full],
]) {
  const missingSemantics = structuredClone(schema5Report);
  delete missingSemantics.providers[1].quotaSemantics;
  const missingSemanticsParsed = parseQuotaAxiJson(
    JSON.stringify(missingSemantics),
    { projection },
  );
  assert(missingSemanticsParsed, `schema-5 ${projection} fixture without semantics did not parse structurally`);
  assert(
    selectActiveProviderQuota(missingSemanticsParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-5 ${projection} output without quota semantics was accepted as fresh`,
  );
}
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
const missingFullRefreshedAt = structuredClone(schema5Full);
delete missingFullRefreshedAt.providers[1].state.refreshedAt;
const missingFullRefreshedAtParsed = parseQuotaAxiJson(
  JSON.stringify(missingFullRefreshedAt),
  { projection: "full" },
);
assert(missingFullRefreshedAtParsed, "schema-5 full fixture missing refreshedAt did not parse structurally");
assert(
  selectActiveProviderQuota(missingFullRefreshedAtParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 full fresh output missing refreshedAt was accepted as fresh",
);
for (const field of ["error", "retryAfter", "remedyCommand"]) {
  const freshWithFailureDiagnostic = structuredClone(schema5Full);
  freshWithFailureDiagnostic.providers[1].state[field] = "unexpected diagnostic";
  const freshWithFailureDiagnosticParsed = parseQuotaAxiJson(
    JSON.stringify(freshWithFailureDiagnostic),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(freshWithFailureDiagnosticParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `fresh provider with ${field} was accepted as fresh`,
  );
}
const codexWithApiSource = structuredClone(schema5Full);
codexWithApiSource.providers[1].source = "api";
codexWithApiSource.providers[1].state.sourcesTried = ["api"];
codexWithApiSource.providers[1].attempts = [{ source: "api", status: "success" }];
const codexWithApiSourceParsed = parseQuotaAxiJson(
  JSON.stringify(codexWithApiSource),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(codexWithApiSourceParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "producer-impossible Codex API source was accepted as fresh",
);
for (const oauthAttempt of [
  { source: "oauth", status: "failed", error: "Codex quota unavailable" },
  { source: "oauth", status: "skipped", error: "credentials_missing" },
]) {
  const cliRpcCodex = structuredClone(schema5Full);
  cliRpcCodex.providers[1].source = "cli-rpc";
  cliRpcCodex.providers[1].state.sourcesTried = ["oauth", "cli-rpc"];
  cliRpcCodex.providers[1].attempts = [
    oauthAttempt,
    { source: "cli-rpc", status: "success" },
  ];
  const cliRpcCodexParsed = parseQuotaAxiJson(
    JSON.stringify(cliRpcCodex),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(cliRpcCodexParsed, "openai-codex", { nowMs: now }).kind === "fresh",
    `valid Codex cli-rpc fallback after ${oauthAttempt.status} OAuth was rejected`,
  );
}
for (const [description, source, attempts] of [
  [
    "foreign attempt source",
    "oauth",
    [
      { source: "bogus", status: "skipped", error: "credentials_missing" },
      { source: "oauth", status: "success" },
    ],
  ],
  [
    "reordered attempts",
    "cli-rpc",
    [
      { source: "cli-rpc", status: "success" },
      { source: "oauth", status: "failed", error: "Codex quota unavailable" },
    ],
  ],
  [
    "missing OAuth failure diagnostic",
    "cli-rpc",
    [
      { source: "oauth", status: "failed" },
      { source: "cli-rpc", status: "success" },
    ],
  ],
  [
    "invalid OAuth skip diagnostic",
    "cli-rpc",
    [
      { source: "oauth", status: "skipped", error: "not_a_credential_state" },
      { source: "cli-rpc", status: "success" },
    ],
  ],
  [
    "Codex credential marker",
    "oauth",
    [{ source: "oauth", status: "success", credentialPresent: true }],
  ],
]) {
  const invalidCodexAttempts = structuredClone(schema5Full);
  invalidCodexAttempts.providers[1].source = source;
  invalidCodexAttempts.providers[1].attempts = attempts;
  invalidCodexAttempts.providers[1].state.sourcesTried = attempts.map((attempt) => attempt.source);
  const invalidCodexAttemptsParsed = parseQuotaAxiJson(
    JSON.stringify(invalidCodexAttempts),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(invalidCodexAttemptsParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `${description} was accepted as fresh Codex provenance`,
  );
}
const scopedCodexReport = structuredClone(schema5Full);
scopedCodexReport.providers = [scopedCodexReport.providers[1]];
assert(
  parseQuotaAxiJson(JSON.stringify(scopedCodexReport), {
    projection: "full",
    expectedProvider: "codex",
  }),
  "exact provider-scoped report was rejected",
);
for (const sibling of [null, { provider: "kimi" }]) {
  const invalidScopedReport = structuredClone(scopedCodexReport);
  invalidScopedReport.providers.push(sibling);
  assert(
    parseQuotaAxiJson(JSON.stringify(invalidScopedReport), {
      projection: "full",
      expectedProvider: "codex",
    }) === null,
    "provider-scoped output with an unexpected sibling was accepted",
  );
}
const missingFullWindowPace = structuredClone(schema5Full);
delete missingFullWindowPace.providers[1].windows[0].pace;
const missingFullWindowPaceParsed = parseQuotaAxiJson(
  JSON.stringify(missingFullWindowPace),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(missingFullWindowPaceParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 full output missing window pace was accepted as fresh",
);
for (const field of ["percentUsed", "percentRemaining"]) {
  const missingPercentage = structuredClone(schema5Full);
  delete missingPercentage.providers[1].windows[0][field];
  const missingPercentageParsed = parseQuotaAxiJson(
    JSON.stringify(missingPercentage),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(missingPercentageParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-5 full Codex output missing ${field} was accepted as fresh`,
  );
}
for (const field of ["pace", "runway", "selection"]) {
  const missingDerived = structuredClone(schema5Full);
  delete missingDerived.providers[1].quotaSemantics.effectiveAvailability[0][field];
  const missingDerivedParsed = parseQuotaAxiJson(
    JSON.stringify(missingDerived),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(missingDerivedParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-5 full output missing availability ${field} was accepted as fresh`,
  );
}
for (const [description, mutate] of [
  ["missing model scope", (entries) => entries.splice(1, 1)],
  ["extra model scope", (entries) => entries.push(structuredClone(entries[1]))],
  ["reordered scopes", (entries) => entries.reverse()],
  ["detached bounds", (entries) => entries[1].boundedBy.pop()],
]) {
  const wrongTopology = structuredClone(schema5Full);
  mutate(wrongTopology.providers[1].quotaSemantics.effectiveAvailability);
  const wrongTopologyParsed = parseQuotaAxiJson(
    JSON.stringify(wrongTopology),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(wrongTopologyParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-5 full output with ${description} was accepted as fresh`,
  );
}
const largeTopology = structuredClone(schema5Full);
const largeProvider = largeTopology.providers[1];
const largeAccountWindows = [{
  id: "weekly",
  label: "week",
  kind: "weekly",
  percentUsed: 50,
  percentRemaining: 50,
  resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString(),
  pace: { status: "unknown", reason: "missing_cycle" },
}];
const largeModelWindows = Array.from({ length: 65 }, (_, index) => {
  const feature = `feature-${index + 1}`;
  const label = `model ${index + 1}`;
  return [
    {
      id: `model:${feature}:5h`,
      label: `${label} session`,
      kind: "model",
      percentUsed: 0,
      percentRemaining: 100,
      resetsAt: new Date(now + 5 * 60 * 60 * 1000).toISOString(),
      pace: { status: "unknown", reason: "missing_cycle" },
    },
    {
      id: `model:${feature}:7d`,
      label: `${label} week`,
      kind: "model",
      percentUsed: 0,
      percentRemaining: 100,
      resetsAt: new Date(now + 6 * 24 * 60 * 60 * 1000).toISOString(),
      pace: { status: "unknown", reason: "missing_cycle" },
    },
  ];
}).flat();
const largeAvailability = (scope, windows) => {
  const boundedBy = windows.map((window) => window.id);
  const effectivePercentRemaining = Math.min(...windows.map((window) => window.percentRemaining));
  return {
    scope,
    status: "known",
    effectivePercentRemaining,
    boundedBy,
    limitingWindowIds: windows
      .filter((window) => window.percentRemaining === effectivePercentRemaining)
      .map((window) => window.id),
    pace: { status: "unknown", unknownWindowIds: boundedBy },
    runway: { status: "unknown", unmeasurableWindowIds: boundedBy },
    selection: { status: "unknown", unmeasurableWindowIds: boundedBy },
  };
};
largeProvider.windows = [...largeAccountWindows, ...largeModelWindows];
largeProvider.quotaSemantics = {
  status: "known",
  description: "Every account window and named model limit is represented.",
  effectiveAvailability: [
    largeAvailability("all_models", largeAccountWindows),
    ...Array.from({ length: 65 }, (_, index) => {
      const scope = `model:feature-${index + 1}`;
      return largeAvailability(
        scope,
        [...largeAccountWindows, largeModelWindows[index * 2], largeModelWindows[index * 2 + 1]],
      );
    }),
  ],
};
const largeTopologyJson = JSON.stringify(largeTopology);
assert(Buffer.byteLength(largeTopologyJson) < 1024 * 1024, "large-topology fixture exceeded the process bound");
const largeTopologyParsed = parseQuotaAxiJson(largeTopologyJson, { projection: "full" });
const largeTopologyView = selectActiveProviderQuota(
  largeTopologyParsed,
  "openai-codex",
  { nowMs: now },
);
assert(largeTopologyView.kind === "fresh", "valid large quota topology was rejected");
assert(
  largeTopologyView.windows.length === largeProvider.windows.length,
  "valid large quota topology dropped windows",
);
const largeTopologyText = formatQuotaStatus(largeTopologyView, 1_000_000, now);
assert(largeTopologyText.includes("model 65 week 100% left"), "large quota footer omitted its final window");
const linearAudit = structuredClone(schema5Full);
const linearProvider = linearAudit.providers[1];
const duplicateCount = 400;
linearProvider.windows = Array.from({ length: duplicateCount }, (_, index) => ({
  ...structuredClone(schema5Full.providers[1].windows[0]),
  id: index === 0 ? "weekly" : `weekly_${index + 1}`,
}));
linearProvider.quotaSemantics = schema5CodexSemantics(linearAudit, true);
const linearParsed = parseQuotaAxiJson(JSON.stringify(linearAudit), { projection: "full" });
const linearAvailability = linearParsed.providers[1].quotaSemantics.effectiveAvailability[0];
let boundedByReads = 0;
linearAvailability.boundedBy = new Proxy(linearAvailability.boundedBy, {
  get(target, property, receiver) {
    if (typeof property === "string" && /^\d+$/.test(property)) boundedByReads += 1;
    return Reflect.get(target, property, receiver);
  },
});
assert(
  selectActiveProviderQuota(linearParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "large audited quota report was rejected",
);
assert(
  boundedByReads < duplicateCount * 30,
  `large audited quota validation was not linear: ${boundedByReads} bound reads`,
);
for (const [description, mutate] of [
  ["invalid first duplicate suffix", (provider) => { provider.windows[0].id = "weekly_1"; }],
  ["arbitrary model identity", (provider) => { provider.windows[1].id = "m1"; }],
  ["mismatched account kind", (provider) => { provider.windows[0].kind = "model"; }],
  ["mismatched model label", (provider) => { provider.windows[1].label = "Spark"; }],
  ["duration-identity mismatch", (provider) => { provider.windows[0].windowSeconds = 18_000; }],
  ["skipped duplicate suffix", (provider) => {
    provider.windows.push({ ...structuredClone(provider.windows[0]), id: "weekly_3" });
  }],
]) {
  const invalidIdentity = structuredClone(schema5Full);
  mutate(invalidIdentity.providers[1]);
  const invalidIdentityParsed = parseQuotaAxiJson(
    JSON.stringify(invalidIdentity),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(invalidIdentityParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `Codex output with ${description} was accepted as fresh`,
  );
}
const duplicateIdentity = structuredClone(schema5Full);
duplicateIdentity.providers[1].windows.splice(1, 0, {
  ...structuredClone(duplicateIdentity.providers[1].windows[0]),
  id: "weekly_2",
});
duplicateIdentity.providers[1].quotaSemantics = schema5CodexSemantics(duplicateIdentity, true);
const duplicateIdentityParsed = parseQuotaAxiJson(
  JSON.stringify(duplicateIdentity),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(duplicateIdentityParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid producer-ordered duplicate Codex identity was rejected",
);
const tenDuplicateIdentities = structuredClone(schema5Full);
tenDuplicateIdentities.providers[1].windows = [
  ...Array.from({ length: 10 }, (_, index) => ({
    ...structuredClone(schema5Full.providers[1].windows[0]),
    id: index === 0 ? "weekly" : `weekly_${index + 1}`,
  })),
  ...tenDuplicateIdentities.providers[1].windows.slice(1),
];
tenDuplicateIdentities.providers[1].quotaSemantics = schema5CodexSemantics(
  tenDuplicateIdentities,
  true,
);
const tenDuplicateIdentitiesParsed = parseQuotaAxiJson(
  JSON.stringify(tenDuplicateIdentities),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(tenDuplicateIdentitiesParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid double-digit Codex duplicate identity was rejected",
);
const longFeatureIdentity = structuredClone(schema5Full);
const longFeature = "f".repeat(201);
longFeatureIdentity.providers[1].windows[1].id = `model:${longFeature}:5h`;
longFeatureIdentity.providers[1].windows[2].id = `model:${longFeature}:7d`;
longFeatureIdentity.providers[1].quotaSemantics = schema5CodexSemantics(longFeatureIdentity, true);
const longFeatureParsed = parseQuotaAxiJson(
  JSON.stringify(longFeatureIdentity),
  { projection: "full" },
);
const longFeatureView = selectActiveProviderQuota(
  longFeatureParsed,
  "openai-codex",
  { nowMs: now },
);
assert(longFeatureView.kind === "fresh", "valid long Codex metered-feature identity was rejected");
assert(
  longFeatureView.windows.some((window) => window.id === `model:${longFeature}:7d`),
  "long Codex metered-feature identity was truncated",
);
const opaqueFeatureIdentity = structuredClone(schema5Full);
const opaqueFeature = "preview  beta";
opaqueFeatureIdentity.providers[1].windows[1].id = `model:${opaqueFeature}:5h`;
opaqueFeatureIdentity.providers[1].windows[2].id = `model:${opaqueFeature}:7d`;
opaqueFeatureIdentity.providers[1].quotaSemantics = schema5CodexSemantics(
  opaqueFeatureIdentity,
  true,
);
const opaqueFeatureParsed = parseQuotaAxiJson(
  JSON.stringify(opaqueFeatureIdentity),
  { projection: "full" },
);
const opaqueFeatureView = selectActiveProviderQuota(
  opaqueFeatureParsed,
  "openai-codex",
  { nowMs: now },
);
assert(opaqueFeatureView.kind === "fresh", "opaque Codex metered-feature identity was rejected");
assert(
  opaqueFeatureView.windows.some((window) => window.id === `model:${opaqueFeature}:7d`),
  "opaque Codex metered-feature identity was normalized",
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
const detachedReport = parseQuotaAxiJson(JSON.stringify(report(now)));
const detachedView = selectActiveProviderQuota(detachedReport, "openai-codex", { nowMs: now });
assert(detachedView.kind === "fresh", "detached quota fixture was not fresh");
detachedReport.providers = new Proxy(detachedReport.providers, {
  get() {
    throw new Error("cached freshness re-read the full report");
  },
});
assert(
  revalidateFreshQuotaView(detachedView, now).kind === "fresh",
  "cached quota freshness did not remain independent of the full report",
);
assert(
  revalidateFreshQuotaView(detachedView, detachedView.freshUntilMs).kind === "stale",
  "cached quota freshness did not expire at its publication deadline",
);
const futureRefreshReport = report(now);
futureRefreshReport.providers[1].state.refreshedAt = new Date(now + 30_000).toISOString();
const futureRefreshParsed = parseQuotaAxiJson(JSON.stringify(futureRefreshReport));
const futureRefreshView = selectActiveProviderQuota(futureRefreshParsed, "openai-codex", { nowMs: now });
assert(futureRefreshView.kind === "fresh", "within-skew refreshed quota was rejected");
assert(
  revalidateFreshQuotaView(futureRefreshView, now - 40_001).kind === "stale",
  "cached quota ignored a future refreshed-at timestamp after a backward clock shift",
);
const publicationSkewReport = parseQuotaAxiJson(JSON.stringify(report(now)));
const publicationSkewView = selectActiveProviderQuota(
  publicationSkewReport,
  "openai-codex",
  { nowMs: now - 120_000 },
);
assert(publicationSkewView.kind === "stale", "future-skewed publication was shown as fresh");
assert(
  publicationSkewView.kind === "stale" &&
    publicationSkewView.recoverable &&
    revalidateFreshQuotaView(publicationSkewView.recoverable, now).kind === "fresh",
  "validated future-skewed publication could not recover within its freshness period",
);
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
let formattedWindowIterations = 0;
const countedFormattingView = {
  ...codex,
  windows: new Proxy(codex.windows, {
    get(target, property, receiver) {
      if (property === Symbol.iterator) formattedWindowIterations += 1;
      return Reflect.get(target, property, receiver);
    },
  }),
};
const cachedFormatter = createQuotaStatusFormatter();
const firstCachedFormat = cachedFormatter(countedFormattingView, 400, now);
const iterationsAfterFirstFormat = formattedWindowIterations;
const secondCachedFormat = cachedFormatter(countedFormattingView, 400, now);
assert(firstCachedFormat === secondCachedFormat, "cached formatter changed stable quota output");
assert(
  formattedWindowIterations === iterationsAfterFirstFormat,
  "stable footer redraw reprocessed every quota window",
);
const resetCacheNow = Math.floor(now / 60_000) * 60_000;
let resetWindowIterations = 0;
const resetRelativeView = {
  ...codex,
  windows: new Proxy([
    { ...codex.windows[0], resetsAtMs: resetCacheNow + 150_000 },
  ], {
    get(target, property, receiver) {
      if (property === Symbol.iterator) resetWindowIterations += 1;
      return Reflect.get(target, property, receiver);
    },
  }),
};
const resetRelativeFormatter = createQuotaStatusFormatter();
const resetThreeMinutes = resetRelativeFormatter(resetRelativeView, 400, resetCacheNow);
assert(resetThreeMinutes.includes("reset 3m"), `initial reset countdown was inaccurate: ${resetThreeMinutes}`);
const resetIterationsBeforeBoundary = resetWindowIterations;
const resetBeforeBoundary = resetRelativeFormatter(resetRelativeView, 400, resetCacheNow + 29_999);
assert(resetBeforeBoundary === resetThreeMinutes, "reset countdown cache expired before its relative boundary");
assert(
  resetWindowIterations === resetIterationsBeforeBoundary,
  "stable reset countdown reprocessed every quota window",
);
const resetTwoMinutes = resetRelativeFormatter(resetRelativeView, 400, resetCacheNow + 30_000);
assert(resetTwoMinutes.includes("reset 2m"), `reset countdown remained cached across its relative boundary: ${resetTwoMinutes}`);
assert(
  resetWindowIterations > resetIterationsBeforeBoundary,
  "reset countdown boundary did not refresh formatted quota",
);
const tinyCreditReport = report(now);
tinyCreditReport.providers[1].credits.remaining = 0.04;
const tinyCreditParsed = parseQuotaAxiJson(JSON.stringify(tinyCreditReport));
assert(tinyCreditParsed, "small positive credit fixture did not parse structurally");
const tinyCreditView = selectActiveProviderQuota(tinyCreditParsed, "openai-codex", { nowMs: now });
const tinyCreditText = formatQuotaStatus(tinyCreditView, 400, now);
assert(tinyCreditText.includes("credits <0.1"), `small positive credits rounded to zero: ${tinyCreditText}`);
assert(!tinyCreditText.includes("credits 0"), `positive credits were presented as zero: ${tinyCreditText}`);
const negativeCreditReport = report(now);
negativeCreditReport.providers[1].credits.remaining = -12.5;
const negativeCreditParsed = parseQuotaAxiJson(JSON.stringify(negativeCreditReport));
assert(negativeCreditParsed, "negative credit fixture did not parse structurally");
const negativeCreditView = selectActiveProviderQuota(negativeCreditParsed, "openai-codex", { nowMs: now });
const negativeCreditText = formatQuotaStatus(negativeCreditView, 400, now);
assert(negativeCreditView.kind === "fresh", `negative credits rejected fresh quota: ${negativeCreditView.kind}`);
assert(negativeCreditText.includes("week 94% left"), `negative credits hid fresh windows: ${negativeCreditText}`);
assert(negativeCreditText.includes("credits -12.5"), `negative credit sign was omitted: ${negativeCreditText}`);
const tinyNegativeCreditReport = report(now);
tinyNegativeCreditReport.providers[1].credits.remaining = -0.04;
const tinyNegativeCreditParsed = parseQuotaAxiJson(JSON.stringify(tinyNegativeCreditReport));
assert(tinyNegativeCreditParsed, "small negative credit fixture did not parse structurally");
const tinyNegativeCreditView = selectActiveProviderQuota(tinyNegativeCreditParsed, "openai-codex", { nowMs: now });
const tinyNegativeCreditText = formatQuotaStatus(tinyNegativeCreditView, 400, now);
assert(tinyNegativeCreditText.includes("credits -<0.1"), `small negative credits lost their sign: ${tinyNegativeCreditText}`);
assert(!tinyNegativeCreditText.includes("credits -0"), `negative credits were presented as zero: ${tinyNegativeCreditText}`);
const tinyPercentReport = report(now);
tinyPercentReport.providers[1].windows[0].percentUsed = 99.96;
tinyPercentReport.providers[1].windows[0].percentRemaining = 0.04;
const tinyPercentParsed = parseQuotaAxiJson(JSON.stringify(tinyPercentReport));
assert(tinyPercentParsed, "small positive percentage fixture did not parse structurally");
const tinyPercentView = selectActiveProviderQuota(tinyPercentParsed, "openai-codex", { nowMs: now });
const tinyPercentText = formatQuotaStatus(tinyPercentView, 400, now);
assert(tinyPercentText.includes("week <0.1% left"), `small positive quota rounded to zero: ${tinyPercentText}`);
assert(!tinyPercentText.includes("week 0% left"), `positive quota was presented as exhausted: ${tinyPercentText}`);
const nearlyFullPercentReport = report(now);
nearlyFullPercentReport.providers[1].windows[0].percentUsed = 0.04;
nearlyFullPercentReport.providers[1].windows[0].percentRemaining = 99.96;
const nearlyFullPercentParsed = parseQuotaAxiJson(JSON.stringify(nearlyFullPercentReport));
assert(nearlyFullPercentParsed, "nearly-full percentage fixture did not parse structurally");
const nearlyFullPercentView = selectActiveProviderQuota(nearlyFullPercentParsed, "openai-codex", { nowMs: now });
const nearlyFullPercentText = formatQuotaStatus(nearlyFullPercentView, 400, now);
assert(
  nearlyFullPercentText.includes("week >99.9% left"),
  `non-full quota rounded to full: ${nearlyFullPercentText}`,
);
assert(!nearlyFullPercentText.includes("| week 100% left"), `non-full quota was presented as full: ${nearlyFullPercentText}`);
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
explicitlyUnverifiedAccount.providers[1].quotaSemantics = schema5CodexSemantics(
  explicitlyUnverifiedAccount,
  false,
);
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
invalidIdentityStatus.providers[1].quotaSemantics = schema5CodexSemantics(
  invalidIdentityStatus,
  false,
);
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
const sourceOnlyKimi = selectActiveProviderQuota(parsed, "kimi-coding", {
  nowMs: now,
  expectedSuccessfulSource: "pi:kimi-coding",
});
assert(sourceOnlyKimi.kind === "unverified", "source-only Pi Kimi quota was accepted without identity");
assert(
  !formatQuotaStatus(sourceOnlyKimi, 200, now).includes("83%"),
  "source-only Pi Kimi provenance exposed quota percentages",
);
const failedKimiSource = report(now);
failedKimiSource.providers[2].attempts[0].status = "failed";
const failedKimiParsed = parseQuotaAxiJson(JSON.stringify(failedKimiSource));
assert(failedKimiParsed, "failed Kimi source fixture did not parse structurally");
assert(
  selectActiveProviderQuota(failedKimiParsed, "kimi-coding", {
    nowMs: now,
    expectedSuccessfulSource: "pi:kimi-coding",
  }).kind === "malformed",
  "fresh Kimi report with no successful source was not rejected as malformed",
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
for (const [reason, detail, compact] of [
  ["provider", "custom-proxy", "Quota: unsupported"],
  ["auth-timeout", "auth timed out", "Quota: auth timeout"],
  ["custom-endpoint", "custom endpoint", "Quota: custom endpoint"],
  ["credential-monitoring", "credential monitoring unavailable", "Quota: monitor failed"],
]) {
  const unsupported = { kind: "unsupported", provider: "custom-proxy", reason };
  const fullUnsupported = formatQuotaStatus(unsupported, 200, now);
  assert(fullUnsupported.includes(detail), `${reason} unavailable state omitted its reason: ${fullUnsupported}`);
  const compactUnsupported = formatQuotaStatus(unsupported, 24, now);
  assert(compactUnsupported === compact, `${reason} unavailable state collapsed narrowly: ${compactUnsupported}`);
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
assert(afterReset.kind === "fresh", "one reset window hid its still-fresh siblings");
assert(afterReset.windows.length === 2, "expired quota window was not removed independently");
const afterResetText = formatQuotaStatus(afterReset, 400, now + 60_000);
assert(!afterResetText.includes("week 94%"), "post-reset quota exposed the expired percentage");
assert(afterResetText.includes("GPT-5.3-Codex-Spark session 100% left"), "post-reset quota hid a fresh sibling window");
assert(afterResetText.includes("plan pro") && afterResetText.includes("credits 0"), "post-reset quota hid fresh metadata");
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
const freshCacheSource = report(now);
freshCacheSource.providers[1].source = "cache";
const freshUnavailableSource = report(now);
freshUnavailableSource.providers[1].source = "unavailable";
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
    timeRemainingPercent: 85.7143,
    elapsedPercent: 14.2857,
    reservePercentPoints: 8.2857,
    burnMultiple: 0.42,
    projectedExhaustedAt: new Date(now + 1_353_600_000).toISOString(),
    projectionConfidence: "established",
    projectionBasis: "cycle_average",
    cycleBasis: "starts_at_resets_at",
    cycleSeconds: 7 * 24 * 60 * 60,
  },
});
populatedProvider.quotaSemantics = {
  status: "known",
  description: "Fixture quota semantics",
  effectiveAvailability: [
    {
      scope: "all_models",
      status: "known",
      effectivePercentRemaining: 94,
      boundedBy: ["weekly"],
      limitingWindowIds: ["weekly"],
      pace: {
        status: "behind",
        behindWindowIds: ["weekly"],
        worstReservePercentPoints: 8.2857,
        worstReserveWindowId: "weekly",
      },
      runway: {
        status: "through_reset",
        projectionConfidence: "established",
        projectionBasis: "cycle_average",
      },
    },
    {
      scope: "model:spark",
      status: "known",
      effectivePercentRemaining: 94,
      boundedBy: ["weekly", "model:spark:5h", "model:spark:7d"],
      limitingWindowIds: ["weekly"],
    },
  ],
};
const fullyPopulatedParsed = parseQuotaAxiJson(JSON.stringify(fullyPopulated));
assert(fullyPopulatedParsed, "fully-populated quota fixture did not parse structurally");
assert(
  selectActiveProviderQuota(fullyPopulatedParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid schema-3 through-reset runway was rejected",
);
const schema3Full = structuredClone(fullyPopulated);
schema3Full.providers[1].windows = [schema3Full.providers[1].windows[0]];
schema3Full.providers[1].quotaSemantics.effectiveAvailability = [
  schema3Full.providers[1].quotaSemantics.effectiveAvailability[0],
];
const schema3FullParsed = parseQuotaAxiJson(
  JSON.stringify(schema3Full),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema3FullParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid schema-3 full projection was rejected",
);
const schema3UnknownPace = structuredClone(schema5Full);
schema3UnknownPace.schemaVersion = 3;
for (const availability of schema3UnknownPace.providers[1].quotaSemantics.effectiveAvailability) {
  delete availability.selection;
}
const schema3UnknownPaceParsed = parseQuotaAxiJson(
  JSON.stringify(schema3UnknownPace),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema3UnknownPaceParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid schema-3 unknown-pace projection was rejected",
);
const schema3MissingWindowPace = structuredClone(schema3UnknownPace);
delete schema3MissingWindowPace.providers[1].windows[0].pace;
const schema3MissingWindowPaceParsed = parseQuotaAxiJson(
  JSON.stringify(schema3MissingWindowPace),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema3MissingWindowPaceParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-3 full output missing window pace was accepted as fresh",
);
const schema3FullWithoutSemantics = structuredClone(schema3Full);
delete schema3FullWithoutSemantics.providers[1].quotaSemantics;
const schema3FullWithoutSemanticsParsed = parseQuotaAxiJson(
  JSON.stringify(schema3FullWithoutSemantics),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema3FullWithoutSemanticsParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-3 full output without quota semantics was accepted as fresh",
);
for (const field of ["pace", "runway"]) {
  const schema3FullWithoutDerivedField = structuredClone(schema3Full);
  delete schema3FullWithoutDerivedField.providers[1].quotaSemantics.effectiveAvailability[0][field];
  const parsedWithoutDerivedField = parseQuotaAxiJson(
    JSON.stringify(schema3FullWithoutDerivedField),
    { projection: "full" },
  );
  assert(
    selectActiveProviderQuota(parsedWithoutDerivedField, "openai-codex", { nowMs: now }).kind === "malformed",
    `schema-3 full output without availability ${field} was accepted as fresh`,
  );
}
const schema5Populated = structuredClone(fullyPopulated);
schema5Populated.schemaVersion = 5;
delete schema5Populated.providers[1].windows[0].pace.projectionBasis;
delete schema5Populated.providers[1].quotaSemantics.effectiveAvailability[0].runway.projectionBasis;
schema5Populated.providers[1].quotaSemantics.effectiveAvailability[0].selection = {
  status: "known",
  spendPriority: 0.6767,
};
for (const window of schema5Populated.providers[1].windows.slice(1)) {
  window.pace = { status: "unknown", reason: "missing_cycle" };
}
for (const availability of schema5Populated.providers[1].quotaSemantics.effectiveAvailability.slice(1)) {
  const unknownWindowIds = availability.boundedBy.filter((id) => id !== "weekly");
  availability.pace = {
    status: "behind",
    behindWindowIds: ["weekly"],
    unknownWindowIds,
    worstReservePercentPoints: 8.2857,
    worstReserveWindowId: "weekly",
  };
  availability.runway = {
    status: "unknown",
    unmeasurableWindowIds: unknownWindowIds,
  };
  availability.selection = {
    status: "unknown",
    unmeasurableWindowIds: unknownWindowIds,
  };
}
const schema5PopulatedParsed = parseQuotaAxiJson(
  JSON.stringify(schema5Populated),
  { projection: "full" },
);
assert(schema5PopulatedParsed, "schema-5 full pace fixture did not parse structurally");
assert(
  selectActiveProviderQuota(schema5PopulatedParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid schema-5 full pace and runway output was rejected",
);
const partialKimi = structuredClone(schema5Populated);
const partialKimiProvider = partialKimi.providers[1];
partialKimi.providers = [{
  ...partialKimiProvider,
  provider: "kimi",
  label: "Kimi",
  source: "api",
  state: {
    ...partialKimiProvider.state,
    sourcesTried: ["pi:kimi-coding"],
    untrustedWindowIds: ["unparsed_limit"],
  },
  attempts: [{ source: "pi:kimi-coding", status: "success" }],
  windows: [partialKimiProvider.windows[0]],
  quotaSemantics: {
    status: "partial",
    description: "Known Kimi windows coexist with an unresolved limit.",
    effectiveAvailability: [{
      scope: "all_models",
      status: "unknown",
      boundedBy: ["weekly"],
      pace: {
        status: "behind",
        behindWindowIds: ["weekly"],
        worstReservePercentPoints: 8.2857,
        worstReserveWindowId: "weekly",
      },
      runway: {
        status: "unknown",
        unmeasurableWindowIds: ["weekly", "unparsed_limit"],
      },
      selection: {
        status: "unknown",
        unmeasurableWindowIds: ["weekly", "unparsed_limit"],
      },
    }],
    unresolvedWindowIds: ["unparsed_limit"],
  },
}];
const partialKimiParsed = parseQuotaAxiJson(JSON.stringify(partialKimi), { projection: "full" });
assert(partialKimiParsed, "partial Kimi full output did not parse structurally");
assert(
  selectActiveProviderQuota(partialKimiParsed, "kimi-coding", { nowMs: now }).kind === "fresh",
  "valid partial Kimi runway with unresolved bounds was rejected",
);
const schema5PaceWithRemovedField = structuredClone(schema5Populated);
schema5PaceWithRemovedField.providers[1].windows[0].pace.projectionBasis = "cycle_average";
const schema5PaceWithRemovedFieldParsed = parseQuotaAxiJson(
  JSON.stringify(schema5PaceWithRemovedField),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema5PaceWithRemovedFieldParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 pace accepted removed projectionBasis metadata",
);
const schema5RunwayWithoutConfidence = structuredClone(schema5Populated);
delete schema5RunwayWithoutConfidence.providers[1].quotaSemantics.effectiveAvailability[0].runway.projectionConfidence;
const schema5RunwayWithoutConfidenceParsed = parseQuotaAxiJson(
  JSON.stringify(schema5RunwayWithoutConfidence),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema5RunwayWithoutConfidenceParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 through-reset runway accepted missing projection confidence",
);
const schema5RunwayWithRemovedField = structuredClone(schema5Populated);
schema5RunwayWithRemovedField.providers[1].quotaSemantics.effectiveAvailability[0].runway.projectionBasis = "cycle_average";
const schema5RunwayWithRemovedFieldParsed = parseQuotaAxiJson(
  JSON.stringify(schema5RunwayWithRemovedField),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(schema5RunwayWithRemovedFieldParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 runway accepted removed projectionBasis metadata",
);
const schema3Projected = structuredClone(fullyPopulated);
const schema3ProjectedProvider = schema3Projected.providers[1];
Object.assign(schema3ProjectedProvider.windows[0], {
  percentUsed: 90,
  percentRemaining: 10,
  pace: {
    status: "ahead",
    timeRemainingPercent: 85.7143,
    elapsedPercent: 14.2857,
    reservePercentPoints: -75.7143,
    burnMultiple: 6.3,
    projectedExhaustedAt: new Date(now + 9_600_000).toISOString(),
    projectionConfidence: "established",
    projectionBasis: "cycle_average",
    cycleBasis: "starts_at_resets_at",
    cycleSeconds: 7 * 24 * 60 * 60,
  },
});
Object.assign(schema3ProjectedProvider.quotaSemantics.effectiveAvailability[0], {
  effectivePercentRemaining: 10,
  limitingWindowIds: ["weekly"],
  pace: {
    status: "ahead",
    aheadWindowIds: ["weekly"],
    worstReservePercentPoints: -75.7143,
    worstReserveWindowId: "weekly",
  },
  runway: {
    status: "projected_exhaustion",
    usableRunwaySeconds: 9_600,
    projectedExhaustedAt: new Date(now + 9_600_000).toISOString(),
    limitingWindowId: "weekly",
    projectionConfidence: "established",
    projectionBasis: "cycle_average",
  },
});
for (const availability of schema3ProjectedProvider.quotaSemantics.effectiveAvailability.slice(1)) {
  availability.effectivePercentRemaining = 10;
  availability.limitingWindowIds = ["weekly"];
}
const schema3ProjectedParsed = parseQuotaAxiJson(JSON.stringify(schema3Projected));
assert(
  selectActiveProviderQuota(schema3ProjectedParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid schema-3 projected-exhaustion runway was rejected",
);
const falseThroughResetRunway = structuredClone(schema3Projected);
falseThroughResetRunway.providers[1].quotaSemantics.effectiveAvailability[0].runway = {
  status: "through_reset",
  projectionConfidence: "established",
  projectionBasis: "cycle_average",
};
const falseThroughResetParsed = parseQuotaAxiJson(JSON.stringify(falseThroughResetRunway));
assert(
  selectActiveProviderQuota(falseThroughResetParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "through-reset runway ignored an earlier bounding-window exhaustion",
);
const wrongProjectedRunway = structuredClone(schema3Projected);
wrongProjectedRunway.providers[1].quotaSemantics.effectiveAvailability[0].runway.usableRunwaySeconds += 1;
const wrongProjectedRunwayParsed = parseQuotaAxiJson(JSON.stringify(wrongProjectedRunway));
assert(
  selectActiveProviderQuota(wrongProjectedRunwayParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "projected runway scalar detached from its bounding window was accepted",
);
const schema3ProjectedWithoutBasis = structuredClone(schema3Projected);
delete schema3ProjectedWithoutBasis.providers[1].quotaSemantics.effectiveAvailability[0].runway.projectionBasis;
const schema3ProjectedWithoutBasisParsed = parseQuotaAxiJson(JSON.stringify(schema3ProjectedWithoutBasis));
assert(
  selectActiveProviderQuota(schema3ProjectedWithoutBasisParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-3 projected-exhaustion runway accepted missing projection basis",
);
const wrongSpendPriority = structuredClone(schema5Populated);
wrongSpendPriority.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.5;
const wrongSpendPriorityParsed = parseQuotaAxiJson(
  JSON.stringify(wrongSpendPriority),
  { projection: "full" },
);
assert(
  selectActiveProviderQuota(wrongSpendPriorityParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-5 selection accepted a scalar detached from its bounding windows",
);
const schema3UnexpectedSelection = structuredClone(fullyPopulated);
schema3UnexpectedSelection.providers[1].quotaSemantics.effectiveAvailability[0].selection = {
  status: "known",
  spendPriority: 0.6767,
};
const schema3UnexpectedSelectionParsed = parseQuotaAxiJson(JSON.stringify(schema3UnexpectedSelection));
assert(
  selectActiveProviderQuota(schema3UnexpectedSelectionParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "schema-3 output accepted a schema-5 selection field",
);
const invalidPercentUsed = structuredClone(fullyPopulated);
invalidPercentUsed.providers[1].windows[0].percentUsed = "invalid";
const inconsistentPercentComplement = structuredClone(fullyPopulated);
inconsistentPercentComplement.providers[1].windows[0].percentUsed = 100;
inconsistentPercentComplement.providers[1].windows[0].percentRemaining = 100;
const invalidPace = structuredClone(fullyPopulated);
invalidPace.providers[1].windows[0].pace.reservePercentPoints = "invalid";
const missingKnownPaceAudit = structuredClone(fullyPopulated);
missingKnownPaceAudit.providers[1].windows[0].pace = { status: "behind" };
const inconsistentKnownPace = structuredClone(fullyPopulated);
inconsistentKnownPace.providers[1].windows[0].pace.reservePercentPoints = 7;
const invalidQuotaSemantics = structuredClone(schema5Populated);
invalidQuotaSemantics.providers[1].quotaSemantics.effectiveAvailability[0].selection.spendPriority = "invalid";
const invalidPaceRelation = structuredClone(fullyPopulated);
invalidPaceRelation.providers[1].windows[0].pace.reason = "stale";
const wrongEffectivePaceSummary = structuredClone(fullyPopulated);
wrongEffectivePaceSummary.providers[1].quotaSemantics.effectiveAvailability[0].pace = {
  status: "ahead",
  aheadWindowIds: ["weekly"],
  worstReservePercentPoints: 8.2857,
  worstReserveWindowId: "weekly",
};
const invalidRunwayRelation = structuredClone(fullyPopulated);
invalidRunwayRelation.providers[1].quotaSemantics.effectiveAvailability[0].runway.status = "unknown";
const falseExhaustedRunway = structuredClone(fullyPopulated);
falseExhaustedRunway.providers[1].quotaSemantics.effectiveAvailability[0].runway = {
  status: "exhausted_now",
  usableRunwaySeconds: 0,
  projectedExhaustedAt: new Date(now).toISOString(),
  limitingWindowId: "weekly",
};
const invalidSelectionRelation = structuredClone(schema5Populated);
invalidSelectionRelation.providers[1].quotaSemantics.effectiveAvailability[0].selection.status = "unknown";
const falseUnknownSelection = structuredClone(schema5Populated);
falseUnknownSelection.providers[1].quotaSemantics.effectiveAvailability[0].selection = {
  status: "unknown",
  unmeasurableWindowIds: ["weekly"],
};
const falseUnknownAvailability = structuredClone(schema5Populated);
Object.assign(falseUnknownAvailability.providers[1].quotaSemantics.effectiveAvailability[0], {
  status: "unknown",
  effectivePercentRemaining: undefined,
  limitingWindowIds: undefined,
});
const falseUnknownSemantics = structuredClone(schema5Populated);
falseUnknownSemantics.providers[1].quotaSemantics = {
  status: "unknown",
  description: "Known Codex bounds mislabeled unknown.",
  effectiveAvailability: [],
};
const missingPaceBlockers = structuredClone(fullyPopulated);
missingPaceBlockers.providers[1].quotaSemantics.effectiveAvailability[0].pace = { status: "unknown" };
const missingRunwayBlockers = structuredClone(fullyPopulated);
missingRunwayBlockers.providers[1].quotaSemantics.effectiveAvailability[0].runway = { status: "unknown" };
const missingSelectionBlockers = structuredClone(schema5Populated);
missingSelectionBlockers.providers[1].quotaSemantics.effectiveAvailability[0].selection = { status: "unknown" };
const foreignSelectionBlocker = structuredClone(schema5Populated);
foreignSelectionBlocker.providers[1].quotaSemantics.effectiveAvailability[0].selection = {
  status: "unknown",
  unmeasurableWindowIds: ["not-a-bound"],
};
const foreignPaceWindow = structuredClone(fullyPopulated);
foreignPaceWindow.providers[1].quotaSemantics.effectiveAvailability[0].pace.behindWindowIds = ["not-a-bound"];
foreignPaceWindow.providers[1].quotaSemantics.effectiveAvailability[0].pace.worstReserveWindowId = "not-a-bound";
const foreignRunwayWindow = structuredClone(fullyPopulated);
foreignRunwayWindow.providers[1].quotaSemantics.effectiveAvailability[0].runway.status = "projected_exhaustion";
foreignRunwayWindow.providers[1].quotaSemantics.effectiveAvailability[0].runway.usableRunwaySeconds = 10;
foreignRunwayWindow.providers[1].quotaSemantics.effectiveAvailability[0].runway.projectedExhaustedAt = new Date(now + 10_000).toISOString();
foreignRunwayWindow.providers[1].quotaSemantics.effectiveAvailability[0].runway.limitingWindowId = "not-a-bound";
const invalidAvailabilityRelation = structuredClone(fullyPopulated);
invalidAvailabilityRelation.providers[1].quotaSemantics.effectiveAvailability[0].status = "unknown";
const duplicateWindowId = structuredClone(fullyPopulated);
duplicateWindowId.providers[1].windows[1].id = "weekly";
const foreignDerivedBound = structuredClone(fullyPopulated);
foreignDerivedBound.providers[1].quotaSemantics.effectiveAvailability[0] = {
  scope: "all_models",
  status: "known",
  effectivePercentRemaining: 1,
  boundedBy: ["ghost"],
  limitingWindowIds: ["ghost"],
};
const duplicateDerivedBound = structuredClone(fullyPopulated);
duplicateDerivedBound.providers[1].quotaSemantics.effectiveAvailability[0] = {
  scope: "all_models",
  status: "known",
  effectivePercentRemaining: 94,
  boundedBy: ["weekly", "weekly"],
  limitingWindowIds: ["weekly"],
};
const wrongEffectivePercentage = structuredClone(fullyPopulated);
wrongEffectivePercentage.providers[1].quotaSemantics.effectiveAvailability[0] = {
  scope: "all_models",
  status: "known",
  effectivePercentRemaining: 1,
  boundedBy: ["weekly"],
  limitingWindowIds: ["weekly"],
};
const wrongLimitingWindow = structuredClone(fullyPopulated);
wrongLimitingWindow.providers[1].quotaSemantics.effectiveAvailability[0] = {
  scope: "all_models",
  status: "known",
  effectivePercentRemaining: 94,
  boundedBy: ["weekly", "model:spark:5h"],
  limitingWindowIds: ["model:spark:5h"],
};
const missingTiedLimiter = structuredClone(fullyPopulated);
missingTiedLimiter.providers[1].windows[1].percentUsed = 6;
missingTiedLimiter.providers[1].windows[1].percentRemaining = 94;
missingTiedLimiter.providers[1].quotaSemantics.effectiveAvailability[0] = {
  scope: "all_models",
  status: "known",
  effectivePercentRemaining: 94,
  boundedBy: ["weekly", "model:spark:5h"],
  limitingWindowIds: ["weekly"],
};
const duplicateAvailabilityScope = structuredClone(fullyPopulated);
duplicateAvailabilityScope.providers[1].quotaSemantics.effectiveAvailability.push(
  structuredClone(duplicateAvailabilityScope.providers[1].quotaSemantics.effectiveAvailability[0]),
);
const invalidAuthStatus = structuredClone(fullyPopulated);
invalidAuthStatus.providers[1].state.authStatus = "invalid";
const freshUnusableAuth = structuredClone(fullyPopulated);
freshUnusableAuth.providers[1].state.authStatus = "unusable";
const freshCredentialExpiryReason = structuredClone(fullyPopulated);
freshCredentialExpiryReason.providers[1].state.reason = "credentials_expired";
freshCredentialExpiryReason.providers[1].state.authStatus = "usable";
const missingFullAttempts = structuredClone(fullyPopulated);
delete missingFullAttempts.providers[1].attempts;
const failedFreshSourceAttempt = structuredClone(fullyPopulated);
failedFreshSourceAttempt.providers[1].attempts[0].status = "failed";
const inconsistentSourcesTried = structuredClone(fullyPopulated);
inconsistentSourcesTried.providers[1].state.sourcesTried = ["cli-rpc"];
const untrustedDisplayedWindow = structuredClone(fullyPopulated);
untrustedDisplayedWindow.providers[1].state.untrustedWindowIds = ["weekly"];
const foreignUntrustedWindow = structuredClone(fullyPopulated);
foreignUntrustedWindow.providers[1].state.untrustedWindowIds = ["ghost"];
const falseUnknownSelectionParsed = parseQuotaAxiJson(
  JSON.stringify(falseUnknownSelection),
  { projection: "full" },
);
assert(falseUnknownSelectionParsed, "false unknown-selection fixture did not parse structurally");
assert(
  selectActiveProviderQuota(falseUnknownSelectionParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "unknown selection despite measurable bounds was accepted as fresh",
);
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
  [freshCacheSource, "fresh state with cache source"],
  [freshUnavailableSource, "fresh state with unavailable source"],
  [unknownProviderStatus, "unknown provider status"],
  [paddedProviderStatus, "normalized provider status"],
  [missingSourcesTried, "missing state sources"],
  [invalidPercentUsed, "invalid percent used"],
  [inconsistentPercentComplement, "inconsistent percentage complement"],
  [invalidPace, "invalid pace field"],
  [missingKnownPaceAudit, "known pace without audit fields"],
  [inconsistentKnownPace, "known pace detached from its window"],
  [invalidQuotaSemantics, "invalid quota semantics field"],
  [invalidPaceRelation, "invalid pace status relation"],
  [wrongEffectivePaceSummary, "effective pace detached from its bounding windows"],
  [invalidRunwayRelation, "invalid runway status relation"],
  [falseExhaustedRunway, "exhausted runway with remaining quota"],
  [invalidSelectionRelation, "invalid selection status relation"],
  [falseUnknownAvailability, "unknown availability despite measurable bounds"],
  [falseUnknownSemantics, "unknown semantics despite recognized bounds"],
  [missingPaceBlockers, "unknown pace without blockers"],
  [missingRunwayBlockers, "unknown runway without blockers"],
  [missingSelectionBlockers, "unknown selection without blockers"],
  [foreignSelectionBlocker, "selection blocker outside its bounds"],
  [foreignPaceWindow, "pace window outside its bounds"],
  [foreignRunwayWindow, "runway window outside its bounds"],
  [invalidAvailabilityRelation, "invalid availability status relation"],
  [duplicateWindowId, "duplicate window identifier"],
  [foreignDerivedBound, "derived bound outside provider windows"],
  [duplicateDerivedBound, "duplicate derived bound"],
  [wrongEffectivePercentage, "effective percentage detached from its bounds"],
  [wrongLimitingWindow, "limiter detached from the minimum bound"],
  [missingTiedLimiter, "incomplete tied limiters"],
  [duplicateAvailabilityScope, "duplicate availability scope"],
  [invalidAuthStatus, "invalid auth status"],
  [freshUnusableAuth, "fresh state with unusable auth"],
  [freshCredentialExpiryReason, "fresh state with expired-credential reason"],
  [missingFullAttempts, "full provider without source attempts"],
  [failedFreshSourceAttempt, "fresh source without a successful attempt"],
  [inconsistentSourcesTried, "state sources detached from ordered attempts"],
  [untrustedDisplayedWindow, "displayed window marked untrusted"],
  [foreignUntrustedWindow, "foreign untrusted window diagnostic"],
]) {
  const structurallyParsed = parseQuotaAxiJson(JSON.stringify(malformedReport));
  assert(structurallyParsed, `${description} fixture should remain structurally parseable`);
  assert(
    selectActiveProviderQuota(structurallyParsed, "openai-codex", { nowMs: now }).kind === "malformed",
    `${description} was accepted as fresh`,
  );
}
const unknownPaceReport = report(now);
unknownPaceReport.providers[1].windows[0].pace = { status: "unknown", reason: "missing_cycle" };
const unknownPaceParsed = parseQuotaAxiJson(JSON.stringify(unknownPaceReport));
assert(
  selectActiveProviderQuota(unknownPaceParsed, "openai-codex", { nowMs: now }).kind === "fresh",
  "valid producer-derived unknown pace reason was rejected",
);
const wrongUnknownPaceReason = structuredClone(unknownPaceReport);
wrongUnknownPaceReason.providers[1].windows[0].pace.reason = "stale";
const wrongUnknownPaceParsed = parseQuotaAxiJson(JSON.stringify(wrongUnknownPaceReason));
assert(
  selectActiveProviderQuota(wrongUnknownPaceParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "unknown pace reason detached from its window was accepted",
);

const staleMixedPace = structuredClone(fullyPopulated);
staleMixedPace.providers[1].source = "cache";
staleMixedPace.providers[1].state.status = "stale";
staleMixedPace.providers[1].state.stale = true;
staleMixedPace.providers[1].state.sourcesTried = ["oauth", "cli-rpc", "cache"];
staleMixedPace.providers[1].attempts = [
  { source: "oauth", status: "failed", error: "Codex quota unavailable" },
  { source: "cli-rpc", status: "failed", error: "Codex quota unavailable" },
];
for (const window of staleMixedPace.providers[1].windows) {
  window.pace = { status: "unknown", reason: "stale" };
}
staleMixedPace.providers[1].quotaSemantics = {
  status: "unknown",
  description: "Stale quota has unknown effective availability",
  effectiveAvailability: [
    {
      scope: "all_models",
      status: "unknown",
      boundedBy: ["weekly"],
      pace: { status: "unknown", unknownWindowIds: ["weekly"] },
      runway: { status: "unknown", unmeasurableWindowIds: ["weekly"] },
    },
    {
      scope: "model:spark",
      status: "unknown",
      boundedBy: ["weekly", "model:spark:5h", "model:spark:7d"],
      pace: {
        status: "unknown",
        unknownWindowIds: ["weekly", "model:spark:5h", "model:spark:7d"],
      },
      runway: {
        status: "unknown",
        unmeasurableWindowIds: ["weekly", "model:spark:5h", "model:spark:7d"],
      },
    },
  ],
};
const staleMixedPaceParsed = parseQuotaAxiJson(JSON.stringify(staleMixedPace), { projection: "full" });
assert(staleMixedPaceParsed, "mixed-pace stale fixture did not parse structurally");
assert(
  selectActiveProviderQuota(staleMixedPaceParsed, "openai-codex", { nowMs: now }).kind === "stale",
  "valid mixed-pace stale projection was mislabeled malformed",
);
const duplicateActiveProvider = report(now);
duplicateActiveProvider.providers.push({ provider: "codex" });
const duplicateActiveProviderParsed = parseQuotaAxiJson(JSON.stringify(duplicateActiveProvider));
assert(duplicateActiveProviderParsed, "duplicate-provider fixture did not parse structurally");
assert(
  selectActiveProviderQuota(duplicateActiveProviderParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "duplicate active-provider rows were accepted as fresh",
);
const uppercaseProvider = report(now);
uppercaseProvider.providers[1].provider = "CODEX";
const uppercaseProviderParsed = parseQuotaAxiJson(JSON.stringify(uppercaseProvider));
assert(uppercaseProviderParsed, "uppercase provider fixture did not parse structurally");
assert(
  selectActiveProviderQuota(uppercaseProviderParsed, "openai-codex", { nowMs: now }).kind === "unavailable",
  "normalized quota provider ID was selected as fresh",
);
const emptyWindows = structuredClone(schema5Full);
emptyWindows.providers[1].windows = [];
emptyWindows.providers[1].quotaSemantics = {
  status: "unknown",
  description: "No quota windows were returned.",
  effectiveAvailability: [],
};
const emptyWindowsParsed = parseQuotaAxiJson(
  JSON.stringify(emptyWindows),
  { projection: "full" },
);
assert(emptyWindowsParsed, "empty-window fixture did not parse structurally");
assert(
  selectActiveProviderQuota(emptyWindowsParsed, "openai-codex", { nowMs: now }).kind === "malformed",
  "fresh full Codex output without quota windows was accepted",
);
const publicationForwardSkew = structuredClone(schema5Full);
publicationForwardSkew.providers[1].windows[0].resetsAt = new Date(now + 3 * 60_000).toISOString();
const publicationForwardParsed = parseQuotaAxiJson(
  JSON.stringify(publicationForwardSkew),
  { projection: "full" },
);
const publicationForwardView = selectActiveProviderQuota(
  publicationForwardParsed,
  "openai-codex",
  { nowMs: now + 4 * 60_000 },
);
assert(publicationForwardView.kind === "fresh", "forward-skewed report was not transiently selectable");
assert(
  !formatQuotaStatus(publicationForwardView, 400, now + 4 * 60_000).includes("week 94% left"),
  "forward-skewed report exposed an already-reset window",
);
const publicationRecoveredView = revalidateFreshQuotaView(publicationForwardView, now + 2 * 60_000);
assert(
  publicationRecoveredView.kind === "fresh" &&
    formatQuotaStatus(publicationRecoveredView, 400, now + 2 * 60_000).includes("week 94% left"),
  "temporary publication-time forward skew discarded a recoverable window",
);
const reportForwardView = selectActiveProviderQuota(
  publicationForwardParsed,
  "openai-codex",
  { nowMs: now + 7 * 60_000 },
);
assert(
  reportForwardView.kind === "stale" && reportForwardView.recoverable,
  "forward-skewed report freshness was not retained safely",
);
assert(
  reportForwardView.kind === "stale" &&
    reportForwardView.recoverable &&
    revalidateFreshQuotaView(reportForwardView.recoverable, now + 2 * 60_000).kind === "fresh",
  "temporary forward skew discarded the validated report publication",
);
assert(selectActiveProviderQuota(parsed, "custom-proxy", { nowMs: now }).kind === "unsupported", "unsupported provider was not isolated");
const ansiReport = report(now);
ansiReport.providers[1].label = "Co\x1b[31mdex";
ansiReport.providers[1].windows[1].label = "週\x1b[0m quota session";
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
await writeFile(process.env.FM_QUOTA_TEST_MODE, "structured_timeout\n");
const structuredTimeout = runQuotaAxiJson({
  timeoutMs: 1000,
  maxOutputBytes: 1024 * 1024,
  full: true,
  provider: "codex",
});
const structuredTimeoutResult = await structuredTimeout.promise;
assert(
  structuredTimeoutResult.kind === "failed" &&
    structuredTimeoutResult.exitCode === 1 &&
    JSON.parse(structuredTimeoutResult.stdout).providers[0].state.error === "Codex quota request timed out",
  "nonzero quota-axi JSON did not retain its bounded stdout and exit status",
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const platformDescriptor = Object.getOwnPropertyDescriptor(process, "platform");
let windowsTimeoutResult;
let windowsKillHeartbeat = false;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "slow\n");
process.env.FM_QUOTA_TEST_TASKKILL_DELAY_SECONDS = "0.15";
try {
  Object.defineProperty(process, "platform", { ...platformDescriptor, value: "win32" });
  const windowsTimeout = runQuotaAxiJson({ timeoutMs: 40, maxOutputBytes: 1024 * 1024 });
  setTimeout(() => {
    windowsKillHeartbeat = true;
  }, 80);
  windowsTimeoutResult = await windowsTimeout.promise;
} finally {
  Object.defineProperty(process, "platform", platformDescriptor);
  delete process.env.FM_QUOTA_TEST_TASKKILL_DELAY_SECONDS;
  await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
}
assert(windowsTimeoutResult?.kind === "timeout", "Windows quota process did not time out");
assert(windowsKillHeartbeat, "Windows process-tree termination blocked the event loop");
const taskkillCalls = (await readFile(process.env.FM_QUOTA_TEST_TASKKILL_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean);
assert(taskkillCalls.length === 1, `Windows timeout did not invoke one process-tree kill: ${taskkillCalls}`);
assert(
  /^\/PID [1-9][0-9]* \/T \/F$/.test(taskkillCalls[0]),
  `Windows timeout did not request bounded tree termination: ${taskkillCalls[0]}`,
);
const windowsDescendantsBefore = (await readFile(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, "utf8"))
  .trim()
  .split(/\s+/)
  .filter(Boolean).length;
const windowsSurvivorsBefore = (await readFile(process.env.FM_QUOTA_TEST_SURVIVORS, "utf8"))
  .trim()
  .split(/\s+/)
  .filter(Boolean).length;
let windowsLeaderExitResult;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "leader_exit\n");
try {
  Object.defineProperty(process, "platform", { ...platformDescriptor, value: "win32" });
  const windowsLeaderExit = runQuotaAxiJson({ timeoutMs: 500, maxOutputBytes: 1024 * 1024 });
  windowsLeaderExitResult = await windowsLeaderExit.promise;
} finally {
  Object.defineProperty(process, "platform", platformDescriptor);
  await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
}
assert(windowsLeaderExitResult?.kind === "ok", "Windows supervisor lost the exited leader result");
const windowsDescendantsAfter = (await readFile(process.env.FM_QUOTA_TEST_DESCENDANT_PIDS, "utf8"))
  .trim()
  .split(/\s+/)
  .filter(Boolean).length;
assert(windowsDescendantsAfter > windowsDescendantsBefore, "Windows leader-exit fixture did not launch a descendant");
await sleep(1100);
const windowsSurvivorsAfter = (await readFile(process.env.FM_QUOTA_TEST_SURVIVORS, "utf8"))
  .trim()
  .split(/\s+/)
  .filter(Boolean).length;
assert(
  windowsSurvivorsAfter === windowsSurvivorsBefore,
  "Windows quota descendant survived after its leader exited",
);
const leaderTaskkillCalls = (await readFile(process.env.FM_QUOTA_TEST_TASKKILL_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean);
assert(
  leaderTaskkillCalls.length === 1,
  `Windows job supervisor required a late tree kill after normal completion: ${leaderTaskkillCalls}`,
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
const officialModelApis = {
  anthropic: "anthropic-messages",
  "github-copilot": "openai-responses",
  "kimi-coding": "anthropic-messages",
  "openai-codex": "openai-codex-responses",
  xai: "openai-responses",
};
function fixtureModel(provider, id = "fixture-model", baseUrl = officialBaseUrls[provider] ?? "https://custom.example.invalid") {
  return { provider, id, api: officialModelApis[provider] ?? "custom-api", baseUrl };
}
function fixtureAccessToken(accountId, additionalClaims = {}) {
  if (!accountId) return "opaque-fixture-token";
  const payload = Buffer.from(JSON.stringify({
    ...additionalClaims,
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `eyJhbGciOiJub25lIn0.${payload}.fixture`;
}
async function setStoredCredential(provider, credential) {
  let credentials = {};
  try {
    credentials = JSON.parse(await readFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, "utf8"));
  } catch {
  }
  credentials[provider] = credential;
  await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, `${JSON.stringify(credentials)}\n`);
}
async function setStoredOAuth(provider, access, expires = Date.now() + 24 * 60 * 60 * 1000) {
  await setStoredCredential(provider, {
    type: "oauth",
    access,
    refresh: `fixture-refresh-${provider}`,
    expires,
  });
}
async function setStoredApiKey(provider, key) {
  await setStoredCredential(provider, { type: "api_key", key });
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
  const providerCompositions = new Map();
  const registeredProviderConfigs = new Map();
  const registeredNativeProviders = new Map();
  function createProviderComposition(providerId) {
    return {
      id: providerId,
      name: `Fixture ${providerId}`,
      baseUrl: officialBaseUrls[providerId],
      auth: {
        oauth: {
          isSubscription: providerOptions.subscription !== false,
          async toAuth(credential) {
            providerOptions.authCalls = (providerOptions.authCalls ?? 0) + 1;
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
      getModels() {
        const model = ctx.model;
        if (!model || model.provider !== providerId) return [];
        return [providerOptions.composedModels ? { ...model } : model];
      },
      stream() {},
      streamSimple() {},
    };
  }
  function providerComposition(providerId) {
    if (!providerCompositions.has(providerId)) {
      providerCompositions.set(providerId, createProviderComposition(providerId));
    }
    return providerCompositions.get(providerId);
  }
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
          getProvider(providerId) {
            return providerComposition(providerId);
          },
          find(providerId, modelId) {
            return providerComposition(providerId).getModels().find((model) => model.id === modelId);
          },
          getRegisteredProviderConfig(providerId) {
            return registeredProviderConfigs.get(providerId);
          },
          getRegisteredNativeProvider(providerId) {
            return registeredNativeProviders.get(providerId);
          },
          isUsingOAuth() {
            return providerOptions.authType !== "api_key";
          },
          getProviderAuthStatus() {
            return {
              configured: true,
              source: providerOptions.authSource ?? "stored",
            };
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
    if (event === "model_select" && payload.model && overrideCtx === ctx) ctx.model = payload.model;
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
    replaceProviderComposition(providerId = ctx.model?.provider) {
      providerCompositions.set(providerId, createProviderComposition(providerId));
    },
    registerProviderOverride(providerId = ctx.model?.provider) {
      registeredProviderConfigs.set(providerId, {
        api: "openai-codex-responses",
        streamSimple() {},
      });
      providerCompositions.set(providerId, createProviderComposition(providerId));
    },
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
const originalReadFileSync = fs.readFileSync;
let synchronousRenderReads = 0;
let renderWithoutAuthIo = "";
try {
  fs.readFileSync = (...args) => {
    synchronousRenderReads += 1;
    return originalReadFileSync(...args);
  };
  syncBuiltinESMExports();
  renderWithoutAuthIo = lifecycle.widgetText(400);
} finally {
  fs.readFileSync = originalReadFileSync;
  syncBuiltinESMExports();
}
assert(renderWithoutAuthIo.includes("week 94% left"), "footer redraw lost cached fresh quota");
assert(synchronousRenderReads === 0, "footer redraw synchronously read credential storage");
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
const callsBeforeKimi = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
await lifecycle.emit("model_select", { model: fixtureModel("kimi-coding", "kimi-fixture") });
await waitFor(
  () => lifecycle.widgetText(240).includes("account correlation unavailable"),
  "Kimi quota without report-side identity was not classified before refresh",
);
assert(!lifecycle.widgetText(240).includes("83%"), "unidentified Kimi quota was presented as active");
await sleep(180);
const callsAfterKimi = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterKimi === callsBeforeKimi, "uncorrelatable Kimi auth invoked quota-axi on cadence");
await lifecycle.emit("model_select", { model: fixtureModel("openai-codex", "codex-cadence") });
await waitFor(
  () => lifecycle.widgetText(400).includes("week 94% left"),
  "supported cadence fixture did not restore Codex quota",
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

await setStoredApiKey("kimi-coding", "fixture-kimi-api-key");
const kimiApiKey = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "kimi-coding",
  "tui",
  { authType: "api_key", authSource: "stored" },
);
await kimiApiKey.emit("session_start", { reason: "startup" });
await waitFor(
  () => kimiApiKey.widgetText(240).includes("account correlation unavailable"),
  `stored Kimi API-key quota without identity was not refused before refresh: ${kimiApiKey.widgetText(240)}`,
);
assert(!kimiApiKey.widgetText(240).includes("83%"), "unidentified Kimi API-key quota was presented as active");
await kimiApiKey.emit("session_shutdown", { reason: "quit" });
const callsBeforeRuntimeKimi = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const runtimeKimiApiKey = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 100 }),
  "kimi-coding",
  "tui",
  { authType: "api_key", authSource: "runtime" },
);
await runtimeKimiApiKey.emit("session_start", { reason: "startup" });
assert(
  runtimeKimiApiKey.widgetText(240).includes("account correlation unavailable"),
  "a Kimi runtime API key was not rejected before quota refresh",
);
await sleep(30);
const callsAfterRuntimeKimi = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterRuntimeKimi === callsBeforeRuntimeKimi, "a non-file Kimi API key invoked quota-axi");
await runtimeKimiApiKey.emit("session_shutdown", { reason: "quit" });
await setStoredOAuth("kimi-coding", "fixture-kimi-coding-access");

await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const switchedFailure = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await switchedFailure.emit("session_start", { reason: "startup" });
await waitFor(
  () => switchedFailure.widgetText(400).includes("week 94% left"),
  "provider-switch failure fixture did not publish initial Codex quota",
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "fail\n");
await switchedFailure.emit("model_select", { model: fixtureModel("openai-codex", "codex-switched") });
await waitFor(
  () => switchedFailure.widgetText(240).includes("quota-axi failed"),
  `provider-switch process failure was hidden by the old report: ${switchedFailure.widgetText(240)}`,
);
assert(!switchedFailure.widgetText(240).includes("week 94%"), "provider switch retained Codex quota");
await switchedFailure.emit("session_shutdown", { reason: "quit" });
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");

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

const liveReconfiguration = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await liveReconfiguration.emit("session_start", { reason: "startup" });
await waitFor(
  () => liveReconfiguration.widgetText(400).includes("week 94% left"),
  "live-reconfiguration fixture did not publish official quota",
);
liveReconfiguration.ctx.model = fixtureModel(
  "openai-codex",
  "fixture-model",
  "https://proxy.example.invalid",
);
const reconfiguredText = liveReconfiguration.widgetText(400);
assert(reconfiguredText.includes("refreshing"), `live endpoint reconfiguration was not detected: ${reconfiguredText}`);
assert(!reconfiguredText.includes("94%"), "live endpoint reconfiguration retained official quota");
await waitFor(
  () => liveReconfiguration.widgetText(240).includes("custom endpoint"),
  `live endpoint reconfiguration was not classified explicitly: ${liveReconfiguration.widgetText(240)}`,
);
liveReconfiguration.ctx.model = fixtureModel("openai-codex");
assert(
  !liveReconfiguration.widgetText(400).includes("94%"),
  "restoring a provider endpoint resurrected quota from a different endpoint revision",
);
await waitFor(
  () => liveReconfiguration.widgetText(400).includes("week 94% left"),
  "restored official endpoint did not refresh quota",
);
await liveReconfiguration.emit("session_shutdown", { reason: "quit" });

const compositionOptions = {};
const liveComposition = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
  "tui",
  compositionOptions,
);
await liveComposition.emit("session_start", { reason: "startup" });
await waitFor(
  () => liveComposition.widgetText(400).includes("week 94% left"),
  "provider-composition fixture did not publish official quota",
);
compositionOptions.authDelayMs = 150;
liveComposition.replaceProviderComposition();
const replacedCompositionText = liveComposition.widgetText(400);
assert(
  replacedCompositionText.includes("refreshing"),
  `provider composition replacement was not detected: ${replacedCompositionText}`,
);
assert(!replacedCompositionText.includes("94%"), "provider composition replacement retained cached quota");
await waitFor(
  () => liveComposition.widgetText(400).includes("week 94% left"),
  "provider composition replacement did not re-resolve quota",
);
await liveComposition.emit("session_shutdown", { reason: "quit" });

const providerOverride = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await providerOverride.emit("session_start", { reason: "startup" });
await waitFor(
  () => providerOverride.widgetText(400).includes("week 94% left"),
  "provider-override fixture did not publish built-in quota",
);
const callsBeforeProviderOverride = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
providerOverride.registerProviderOverride();
const overriddenProviderText = providerOverride.widgetText(240);
assert(
  overriddenProviderText.includes("provider override"),
  `custom provider implementation was not rejected: ${overriddenProviderText}`,
);
assert(!overriddenProviderText.includes("94%"), "custom provider implementation retained built-in quota");
await sleep(30);
const callsAfterProviderOverride = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(
  callsAfterProviderOverride === callsBeforeProviderOverride,
  "custom provider implementation invoked quota-axi",
);
await providerOverride.emit("session_shutdown", { reason: "quit" });

const modelsJsonOverlay = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await modelsJsonOverlay.emit("session_start", { reason: "startup" });
await waitFor(
  () => modelsJsonOverlay.widgetText(400).includes("week 94% left"),
  "models.json overlay fixture did not publish built-in quota",
);
const callsBeforeModelsJsonOverlay = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
modelsJsonOverlay.ctx.model = {
  ...fixtureModel("openai-codex"),
  api: "openai-responses",
};
const modelsJsonOverlayText = modelsJsonOverlay.widgetText(240);
assert(
  modelsJsonOverlayText.includes("provider override"),
  `models.json API overlay was not rejected: ${modelsJsonOverlayText}`,
);
assert(!modelsJsonOverlayText.includes("94%"), "models.json API overlay retained built-in quota");
await sleep(30);
const callsAfterModelsJsonOverlay = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(
  callsAfterModelsJsonOverlay === callsBeforeModelsJsonOverlay,
  "models.json API overlay invoked quota-axi",
);
await modelsJsonOverlay.emit("session_shutdown", { reason: "quit" });

await writeFile(`${process.env.PI_CODING_AGENT_DIR}/models.json`, `{
  // Pi models.json accepts line comments and trailing commas.
  "providers": {
    "unrelated-provider": {
      "baseUrl": "https://example.invalid/api",
    },
  },
}`);
const commentedModelsJson = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await commentedModelsJson.emit("session_start", { reason: "startup" });
await waitFor(
  () => commentedModelsJson.widgetText(400).includes("week 94% left"),
  `valid commented models.json suppressed quota: ${commentedModelsJson.widgetText(400)}`,
);
await commentedModelsJson.emit("session_shutdown", { reason: "quit" });

const commandHeaderOptions = { composedModels: true };
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/models.json`, JSON.stringify({
  providers: {
    "openai-codex": {
      headers: { Authorization: "!sleep 30" },
    },
  },
}));
const callsBeforeCommandHeader = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
const commandHeaderOverlay = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
  "tui",
  commandHeaderOptions,
);
await fs.promises.rm(`${process.env.PI_CODING_AGENT_DIR}/models.json`);
await commandHeaderOverlay.emit("session_start", { reason: "startup" });
await waitFor(
  () => commandHeaderOverlay.widgetText(240).includes("provider override"),
  `command-backed provider headers were not rejected before auth resolution: ${commandHeaderOverlay.widgetText(240)}`,
);
const callsAfterCommandHeader = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(commandHeaderOptions.authCalls === undefined, "command-backed headers reached the effective auth resolver");
assert(callsAfterCommandHeader === callsBeforeCommandHeader, "command-backed headers invoked quota-axi");
await commandHeaderOverlay.emit("session_shutdown", { reason: "quit" });

const delayedAuthWatcher = new EventEmitter();
delayedAuthWatcher.close = () => {};
let notifyDelayedAuthChange;
const delayedAuthOptions = { authType: "api_key" };
const delayedAuthSync = makePi(
  createFirstmateQuotaStatusExtension({
    refreshMs: 60_000,
    timeoutMs: 500,
    watchAuthDirectory(_path, _options, listener) {
      notifyDelayedAuthChange = listener;
      return delayedAuthWatcher;
    },
  }),
  "openai-codex",
  "tui",
  delayedAuthOptions,
);
await delayedAuthSync.emit("session_start", { reason: "startup" });
assert(
  delayedAuthSync.widgetText(240).includes("non-subscription auth"),
  "pre-login auth mode was not explicit",
);
notifyDelayedAuthChange("change", "auth.json");
await sleep(50);
assert(
  delayedAuthSync.widgetText(240).includes("non-subscription auth"),
  "credential watcher did not resolve against the initial runtime auth mode",
);
delayedAuthOptions.authType = "oauth";
await waitFor(
  () => delayedAuthSync.widgetText(400).includes("week 94% left"),
  `post-login runtime auth synchronization was not detected: ${delayedAuthSync.widgetText(400)}`,
);
await delayedAuthSync.emit("session_shutdown", { reason: "quit" });

const repairedCorrelationWatcher = new EventEmitter();
repairedCorrelationWatcher.close = () => {};
let notifyRepairedCorrelation;
await setStoredOAuth("openai-codex", "opaque-fixture-token");
const repairedCorrelation = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
  watchAuthDirectory(_path, _options, listener) {
    notifyRepairedCorrelation = listener;
    return repairedCorrelationWatcher;
  },
}));
await repairedCorrelation.emit("session_start", { reason: "startup" });
await waitFor(
  () => repairedCorrelation.widgetText(240).includes("account correlation unavailable"),
  `uncorrelatable login was not explicit: ${repairedCorrelation.widgetText(240)}`,
);
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));
notifyRepairedCorrelation("change", "auth.json");
await waitFor(
  () => repairedCorrelation.widgetText(400).includes("week 94% left"),
  `repaired account correlation did not refresh after credential change: ${repairedCorrelation.widgetText(400)}`,
);
await repairedCorrelation.emit("session_shutdown", { reason: "quit" });

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

const cachedAuthTimeoutOptions = {};
const cachedAuthTimeout = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 200, timeoutMs: 500 }),
  "openai-codex",
  "tui",
  cachedAuthTimeoutOptions,
);
await cachedAuthTimeout.emit("session_start", { reason: "startup" });
await waitFor(
  () => cachedAuthTimeout.widgetText(400).includes("week 94% left"),
  "auth-timeout cache fixture did not publish initial quota",
);
cachedAuthTimeoutOptions.authDelayMs = 1000;
await waitFor(
  () => cachedAuthTimeout.widgetText(400).includes("auth timed out"),
  `refresh auth timeout was not exposed: ${cachedAuthTimeout.widgetText(400)}`,
);
assert(
  cachedAuthTimeout.widgetText(400).includes("week 94% left"),
  "refresh auth timeout discarded independently fresh quota",
);
await cachedAuthTimeout.emit("session_shutdown", { reason: "quit" });

const modelsReadFailure = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 150,
  timeoutMs: 500,
}));
await modelsReadFailure.emit("session_start", { reason: "startup" });
await waitFor(
  () => modelsReadFailure.widgetText(400).includes("week 94% left"),
  "models-read-failure fixture did not publish initial quota",
);
const callsBeforeMalformedModels = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/models.json`, "{\n");
await waitFor(
  async () => (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
    .trim()
    .split(/\n/)
    .filter(Boolean).length > callsBeforeMalformedModels,
  "quota did not refresh against Pi's unchanged effective provider",
);
assert(
  modelsReadFailure.widgetText(400).includes("week 94% left") &&
    !modelsReadFailure.widgetText(400).includes("auth unavailable"),
  "an unapplied models.json write changed effective-provider quota",
);
await modelsReadFailure.emit("session_shutdown", { reason: "quit" });
await fs.promises.rm(`${process.env.PI_CODING_AGENT_DIR}/models.json`);

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

const savedAuthFile = await readFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, "utf8");
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, JSON.stringify({
  "openai-codex": {
    type: "oauth",
    access: fixtureAccessToken("fixture-codex-account"),
    refresh: "fixture-refresh-openai-codex",
    expires: Date.now() + 24 * 60 * 60 * 1000,
    padding: "x".repeat(2048),
  },
}));
const callsBeforeOversizedAuth = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const oversizedAuth = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 100,
  maxAuthBytes: 256,
}));
await oversizedAuth.emit("session_start", { reason: "startup" });
await waitFor(
  () => oversizedAuth.widgetText(240).includes("auth data too large"),
  `oversized auth storage was not rejected explicitly: ${oversizedAuth.widgetText(240)}`,
);
const callsAfterOversizedAuth = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterOversizedAuth === callsBeforeOversizedAuth, "oversized auth storage invoked quota-axi");
await oversizedAuth.emit("session_shutdown", { reason: "quit" });
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, savedAuthFile);

await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));
const unrelatedCredentialWrite = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
}));
await unrelatedCredentialWrite.emit("session_start", { reason: "startup" });
await waitFor(
  () => unrelatedCredentialWrite.widgetText(400).includes("week 94% left"),
  "unrelated-credential fixture did not publish initial quota",
);
const callsBeforeUnrelatedCredential = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
await setStoredOAuth("anthropic", "replacement-anthropic-access");
await sleep(100);
const callsAfterUnrelatedCredential = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(
  unrelatedCredentialWrite.widgetText(400).includes("week 94% left"),
  "unrelated credential write invalidated active-provider quota",
);
assert(
  callsAfterUnrelatedCredential === callsBeforeUnrelatedCredential,
  "unrelated credential write invoked quota-axi",
);
await unrelatedCredentialWrite.emit("session_shutdown", { reason: "quit" });

const credentialChangeWatcher = new EventEmitter();
credentialChangeWatcher.close = () => {};
let notifyCredentialChange;
const credentialChange = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
  watchAuthDirectory(_path, _options, listener) {
    notifyCredentialChange = listener;
    return credentialChangeWatcher;
  },
}));
await credentialChange.emit("session_start", { reason: "startup" });
await waitFor(
  () => credentialChange.widgetText(400).includes("week 94% left"),
  "credential-change fixture did not publish initial account quota",
);
await setStoredOAuth("openai-codex", fixtureAccessToken("replacement-codex-account"));
notifyCredentialChange("change", "auth.json");
assert(
  !credentialChange.widgetText(400).includes("94%"),
  "credential change remained visible while its revision check was pending",
);
await waitFor(
  () => !credentialChange.widgetText(400).includes("94%"),
  "credential change remained fresh after watcher invalidation",
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

const transientCredentialWatcher = new EventEmitter();
let transientCredentialWatcherCloses = 0;
transientCredentialWatcher.close = () => {
  transientCredentialWatcherCloses += 1;
};
let notifyTransientCredentialChange;
const transientCredentialRead = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
  watchAuthDirectory(_path, _options, listener) {
    notifyTransientCredentialChange = listener;
    return transientCredentialWatcher;
  },
}));
await transientCredentialRead.emit("session_start", { reason: "startup" });
await waitFor(
  () => transientCredentialRead.widgetText(400).includes("week 94% left"),
  "transient credential-read fixture did not publish initial quota",
);
const validCredentialStorage = await readFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, "utf8");
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, "{\n");
notifyTransientCredentialChange("change", "auth.json");
assert(
  !transientCredentialRead.widgetText(400).includes("94%"),
  "temporarily unverifiable credentials retained cached quota",
);
await waitFor(
  () => transientCredentialRead.widgetText(240).includes("auth unavailable"),
  `transient credential-read failure was not explicit: ${transientCredentialRead.widgetText(240)}`,
);
assert(transientCredentialWatcherCloses === 0, "transient credential-read failure closed the healthy watcher");
await writeFile(`${process.env.PI_CODING_AGENT_DIR}/auth.json`, validCredentialStorage);
notifyTransientCredentialChange("change", "auth.json");
await waitFor(
  () => transientCredentialRead.widgetText(400).includes("week 94% left"),
  `repaired credential storage did not restore fresh quota: ${transientCredentialRead.widgetText(400)}`,
);
assert(transientCredentialWatcherCloses === 0, "repaired credential storage did not retain its watcher");
await transientCredentialRead.emit("session_shutdown", { reason: "quit" });
assert(transientCredentialWatcherCloses === 1, "credential watcher was not closed at shutdown");

const silentCredentialWatcher = new EventEmitter();
silentCredentialWatcher.close = () => {};
let runMissedCredentialRevisionCheck;
const missedCredentialTimers = {
  setTimeout(callback, delayMs) {
    return setTimeout(callback, delayMs);
  },
  clearTimeout(timer) {
    clearTimeout(timer);
  },
  setInterval(callback, delayMs) {
    if (delayMs === 1000) runMissedCredentialRevisionCheck = callback;
    return { delayMs };
  },
  clearInterval() {},
};
const missedCredentialEvent = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 60_000,
  timeoutMs: 500,
  timers: missedCredentialTimers,
  watchAuthDirectory() {
    return silentCredentialWatcher;
  },
}));
await missedCredentialEvent.emit("session_start", { reason: "startup" });
await waitFor(
  () => missedCredentialEvent.widgetText(400).includes("week 94% left"),
  "missed-event fixture did not publish initial account quota",
);
assert(runMissedCredentialRevisionCheck, "missed-event fixture did not schedule revision checks");
await setStoredOAuth("openai-codex", fixtureAccessToken("replacement-codex-account"));
runMissedCredentialRevisionCheck();
await waitFor(
  () => !missedCredentialEvent.widgetText(400).includes("94%"),
  "periodic credential revision check retained old-account quota after a missed watch event",
);
await waitFor(
  () => missedCredentialEvent.widgetText(240).includes("account unverified"),
  `missed credential event was not re-correlated: ${missedCredentialEvent.widgetText(240)}`,
);
await missedCredentialEvent.emit("session_shutdown", { reason: "quit" });
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));

const failedWatcher = new EventEmitter();
failedWatcher.close = () => {};
const watcherFailure = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 40,
  timeoutMs: 500,
  watchAuthDirectory() {
    return failedWatcher;
  },
}));
await watcherFailure.emit("session_start", { reason: "startup" });
await waitFor(
  () => watcherFailure.widgetText(400).includes("week 94% left"),
  "watcher-failure fixture did not publish initial account quota",
);
const callsBeforeWatcherError = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
failedWatcher.emit("error", new Error("fixture watcher failure"));
await setStoredOAuth("openai-codex", fixtureAccessToken("replacement-codex-account"));
await waitFor(
  () => watcherFailure.widgetText(300).includes("credential monitoring unavailable"),
  `watcher failure did not expose unavailable monitoring: ${watcherFailure.widgetText(300)}`,
);
assert(!watcherFailure.widgetText(400).includes("94%"), "watcher failure retained old-account quota");
await sleep(120);
const callsAfterWatcherError = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterWatcherError === callsBeforeWatcherError, "failed credential monitoring continued quota refreshes");
await watcherFailure.emit("session_shutdown", { reason: "quit" });
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));

const callsBeforeWatcherSetupFailure = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
const watcherSetupFailure = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 40,
  timeoutMs: 100,
  watchAuthDirectory() {
    throw new Error("fixture watcher setup failure");
  },
}));
await watcherSetupFailure.emit("session_start", { reason: "startup" });
assert(
  watcherSetupFailure.widgetText(300).includes("credential monitoring unavailable"),
  `watcher setup failure was not explicit: ${watcherSetupFailure.widgetText(300)}`,
);
await sleep(120);
const callsAfterWatcherSetupFailure = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(callsAfterWatcherSetupFailure === callsBeforeWatcherSetupFailure, "missing credential monitoring invoked quota-axi");
await watcherSetupFailure.emit("session_shutdown", { reason: "quit" });

const callsBeforeIndependentWatcherFailures = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
for (const [provider, expected] of [
  ["custom-provider", "Quota: unavailable for custom-provider"],
  [null, "Quota: unavailable (no model)"],
]) {
  const independentWatcherFailure = makePi(createFirstmateQuotaStatusExtension({
    refreshMs: 40,
    timeoutMs: 100,
    watchAuthDirectory() {
      throw new Error("fixture watcher setup failure");
    },
  }), provider);
  await independentWatcherFailure.emit("session_start", { reason: "startup" });
  const independentText = independentWatcherFailure.widgetText(300);
  assert(independentText.includes(expected), `watcher failure replaced independent state: ${independentText}`);
  assert(!independentText.includes("credential monitoring"), `independent state blamed credential monitoring: ${independentText}`);
  await sleep(120);
  await independentWatcherFailure.emit("session_shutdown", { reason: "quit" });
}
const callsAfterIndependentWatcherFailures = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8")).trim().split(/\n/).filter(Boolean).length;
assert(
  callsAfterIndependentWatcherFailures === callsBeforeIndependentWatcherFailures,
  "credential-independent targets invoked quota-axi after watcher failure",
);

for (const reason of ["reload", "new", "resume", "fork"]) {
  lifecycle.ctx.model = fixtureModel("openai-codex", "codex-fixture");
  await lifecycle.emit("session_start", { reason });
  await waitFor(
    () => lifecycle.widgetText(240).includes("week 94% left"),
    `${reason} did not correlate the active Codex account`,
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

class SplitClock {
  constructor(wallNowMs) {
    this.wallNowMs = wallNowMs;
    this.timerNowMs = 0;
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
    const effectiveDelayMs = delayMs > 2_147_483_647 ? 1 : delayMs;
    this.tasks.set(id, { id, callback, at: this.timerNowMs + effectiveDelayMs, intervalMs });
    return id;
  }
  advanceTimers(milliseconds) {
    const target = this.timerNowMs + milliseconds;
    for (;;) {
      const task = [...this.tasks.values()]
        .filter((candidate) => candidate.at <= target)
        .sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!task) break;
      this.timerNowMs = task.at;
      if (task.intervalMs === null) this.tasks.delete(task.id);
      else task.at += task.intervalMs;
      task.callback();
    }
    this.timerNowMs = target;
  }
  advanceTimersDelayed(milliseconds) {
    const target = this.timerNowMs + milliseconds;
    this.timerNowMs = target;
    for (;;) {
      const task = [...this.tasks.values()]
        .filter((candidate) => candidate.at <= target)
        .sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!task) break;
      if (task.intervalMs === null) this.tasks.delete(task.id);
      else task.at += task.intervalMs;
      task.callback();
    }
  }
}

const backwardExpiryStart = Date.now();
const backwardExpiryClock = new SplitClock(backwardExpiryStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(backwardExpiryStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(60_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  backwardExpiryStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const backwardExpiry = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => backwardExpiryClock.wallNowMs,
  monotonicNow: () => backwardExpiryClock.timerNowMs,
  timers: backwardExpiryClock.timers,
}));
await backwardExpiry.emit("session_start", { reason: "startup" });
await waitFor(
  () => backwardExpiry.widgetText(400).includes("week 94% left"),
  "backward-expiry fixture did not publish its first window",
);
backwardExpiryClock.wallNowMs -= 120_000;
const writesBeforeEarlyTimer = backwardExpiry.widgetWriteCount;
backwardExpiryClock.advanceTimers(60_000);
assert(backwardExpiry.widgetWriteCount > writesBeforeEarlyTimer, "expiry timer did not revalidate after a clock shift");
assert(
  backwardExpiry.widgetText(400).includes("stale") &&
    !backwardExpiry.widgetText(400).includes("week 94% left"),
  "a future-skewed report was presented as fresh",
);
backwardExpiryClock.wallNowMs += 120_000;
assert(
  !backwardExpiry.widgetText(400).includes("week 94% left"),
  "clock recovery resurrected a monotonically expired window",
);
assert(
  backwardExpiry.widgetText(400).includes("GPT-5.3-Codex-Spark session 100% left"),
  "monotonic expiry hid a fresh sibling window",
);
await backwardExpiry.emit("session_shutdown", { reason: "quit" });
assert(backwardExpiryClock.tasks.size === 0, "backward-clock expiry leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const forwardExpiryStart = Date.now();
const forwardExpiryClock = new SplitClock(forwardExpiryStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(forwardExpiryStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(3 * 60_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  forwardExpiryStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const forwardExpiry = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => forwardExpiryClock.wallNowMs,
  monotonicNow: () => forwardExpiryClock.timerNowMs,
  timers: forwardExpiryClock.timers,
}));
await forwardExpiry.emit("session_start", { reason: "startup" });
await waitFor(
  () => forwardExpiry.widgetText(400).includes("week 94% left"),
  "forward-expiry fixture did not publish its first window",
);
forwardExpiryClock.wallNowMs = forwardExpiryStart + 4 * 60_000;
assert(
  !forwardExpiry.widgetText(400).includes("week 94% left"),
  "forward clock jump exposed a reset quota window",
);
forwardExpiryClock.wallNowMs = forwardExpiryStart + 2 * 60_000;
assert(
  forwardExpiry.widgetText(400).includes("week 94% left"),
  "temporary forward clock jump tombstoned a still-fresh quota window",
);
await forwardExpiry.emit("session_shutdown", { reason: "quit" });
assert(forwardExpiryClock.tasks.size === 0, "forward-clock expiry leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const reportForwardStart = Date.now();
const reportForwardClock = new SplitClock(reportForwardStart + 7 * 60_000);
process.env.FM_QUOTA_TEST_NOW_MS = String(reportForwardStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(3 * 60_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  reportForwardStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const reportForward = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => reportForwardClock.wallNowMs,
  monotonicNow: () => reportForwardClock.timerNowMs,
  timers: reportForwardClock.timers,
}));
await reportForward.emit("session_start", { reason: "startup" });
await waitFor(
  () => reportForward.widgetText(400).includes("stale"),
  "forward-skewed report was not withheld at publication",
);
assert(!reportForward.widgetText(400).includes("94%"), "forward-skewed report exposed stale quota");
reportForwardClock.wallNowMs = reportForwardStart + 2 * 60_000;
assert(
  reportForward.widgetText(400).includes("week 94% left"),
  "temporary forward report skew discarded a recoverable publication",
);
reportForwardClock.advanceTimers(3 * 60_000);
assert(
  !reportForward.widgetText(400).includes("week 94% left"),
  "monotonic report expiry did not retire a reset window",
);
reportForwardClock.wallNowMs = reportForwardStart + 60_000;
assert(
  !reportForward.widgetText(400).includes("week 94% left"),
  "wall rollback resurrected a monotonically expired report window",
);
assert(
  reportForward.widgetText(400).includes("GPT-5.3-Codex-Spark session 100% left"),
  "report expiry hid an independently fresh sibling",
);
await reportForward.emit("session_shutdown", { reason: "quit" });
assert(reportForwardClock.tasks.size === 0, "forward-report skew leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const publicationSkewStart = Date.now();
const publicationSkewClock = new SplitClock(publicationSkewStart);
publicationSkewClock.wallNowMs -= 120_000;
process.env.FM_QUOTA_TEST_NOW_MS = String(publicationSkewStart);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  publicationSkewStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const publicationSkew = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => publicationSkewClock.wallNowMs,
  monotonicNow: () => publicationSkewClock.timerNowMs,
  timers: publicationSkewClock.timers,
}));
await publicationSkew.emit("session_start", { reason: "startup" });
await waitFor(
  () => publicationSkew.widgetText(400).includes("stale"),
  "future-skewed initial report was not withheld",
);
assert(!publicationSkew.widgetText(400).includes("94%"), "future-skewed initial report exposed quota values");
await writeFile(process.env.FM_QUOTA_TEST_MODE, "fail\n");
publicationSkewClock.advanceTimers(5 * 60 * 1000);
await waitFor(
  () => publicationSkew.widgetText(400).includes("quota-axi failed"),
  "refresh failure during recoverable skew was not explicit",
);
publicationSkewClock.wallNowMs = publicationSkewStart;
assert(
  publicationSkew.widgetText(400).includes("week 94% left"),
  "refresh failure discarded a recoverable initial report",
);
await publicationSkew.emit("session_shutdown", { reason: "quit" });
assert(publicationSkewClock.tasks.size === 0, "recoverable publication skew leaked a timer");
delete process.env.FM_QUOTA_TEST_NOW_MS;

const processAgeStart = Date.now();
process.env.FM_QUOTA_TEST_NOW_MS = String(processAgeStart);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  processAgeStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const callsBeforeProcessAge = fs.readFileSync(process.env.FM_QUOTA_TEST_CALLS, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
const processAge = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => processAgeStart,
  monotonicNow: () => {
    const calls = fs.readFileSync(process.env.FM_QUOTA_TEST_CALLS, "utf8")
      .trim()
      .split(/\n/)
      .filter(Boolean).length;
    return calls > callsBeforeProcessAge ? 7 * 60 * 1000 : 0;
  },
}));
await processAge.emit("session_start", { reason: "startup" });
await waitFor(
  () => processAge.widgetText(400).includes("stale"),
  "quota process age was not included in publication freshness",
);
assert(!processAge.widgetText(400).includes("94%"), "expired process output was published as fresh");
await processAge.emit("session_shutdown", { reason: "quit" });
delete process.env.FM_QUOTA_TEST_NOW_MS;

const postStartupGenerationStart = Date.now();
const postStartupGenerationDelayMs = 15_000;
process.env.FM_QUOTA_TEST_NOW_MS = String(postStartupGenerationStart + postStartupGenerationDelayMs);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(10_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  postStartupGenerationStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const callsBeforePostStartupGeneration = fs.readFileSync(process.env.FM_QUOTA_TEST_CALLS, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
const postStartupGeneration = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => {
    const calls = fs.readFileSync(process.env.FM_QUOTA_TEST_CALLS, "utf8")
      .trim()
      .split(/\n/)
      .filter(Boolean).length;
    return postStartupGenerationStart + (calls > callsBeforePostStartupGeneration
      ? postStartupGenerationDelayMs
      : 0);
  },
  monotonicNow: () => {
    const calls = fs.readFileSync(process.env.FM_QUOTA_TEST_CALLS, "utf8")
      .trim()
      .split(/\n/)
      .filter(Boolean).length;
    return calls > callsBeforePostStartupGeneration ? postStartupGenerationDelayMs : 0;
  },
}));
await postStartupGeneration.emit("session_start", { reason: "startup" });
await waitFor(
  () => postStartupGeneration.widgetText(400).includes("week 94% left"),
  "pre-generation startup time expired a newly generated quota window",
);
await postStartupGeneration.emit("session_shutdown", { reason: "quit" });
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const overflowSkewStart = Date.now();
const overflowSkewClock = new SplitClock(overflowSkewStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(overflowSkewStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(60_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  overflowSkewStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const overflowSkew = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => overflowSkewClock.wallNowMs,
  monotonicNow: () => overflowSkewClock.timerNowMs,
  timers: overflowSkewClock.timers,
}));
await overflowSkew.emit("session_start", { reason: "startup" });
await waitFor(
  () => overflowSkew.widgetText(400).includes("week 94% left"),
  "large-skew fixture did not publish fresh quota",
);
overflowSkewClock.wallNowMs -= 2_147_483_647 + 120_000;
overflowSkewClock.advanceTimers(60_000);
assert(overflowSkew.widgetText(400).includes("stale"), "large backward skew remained fresh");
const writesAfterLargeSkew = overflowSkew.widgetWriteCount;
overflowSkewClock.advanceTimers(1);
assert(
  overflowSkew.widgetWriteCount === writesAfterLargeSkew,
  "oversized expiry delay collapsed into a one-millisecond render loop",
);
overflowSkewClock.wallNowMs = overflowSkewStart;
assert(
  !overflowSkew.widgetText(400).includes("week 94% left"),
  "large-skew recovery resurrected a monotonically expired window",
);
assert(
  overflowSkew.widgetText(400).includes("GPT-5.3-Codex-Spark session 100% left"),
  "large-skew expiry hid a still-fresh sibling window",
);
await overflowSkew.emit("session_shutdown", { reason: "quit" });
assert(overflowSkewClock.tasks.size === 0, "large-skew expiry leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const siblingStart = Date.now();
const siblingClock = new FakeClock(siblingStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(siblingStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(60_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  siblingStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const independentlyExpiring = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => siblingClock.nowMs,
  timers: siblingClock.timers,
}));
await independentlyExpiring.emit("session_start", { reason: "startup" });
await waitFor(
  () => independentlyExpiring.widgetText(400).includes("week 94% left"),
  "independent-expiry fixture did not publish its first window",
);
const writesBeforeWindowReset = independentlyExpiring.widgetWriteCount;
siblingClock.advance(60_000);
assert(independentlyExpiring.widgetWriteCount > writesBeforeWindowReset, "window reset did not republish quota");
const siblingText = independentlyExpiring.widgetText(400);
assert(!siblingText.includes("week 94%"), "reset quota window remained visible as fresh");
assert(siblingText.includes("GPT-5.3-Codex-Spark session 100% left"), "reset quota window hid a fresh sibling");
assert(siblingText.includes("plan pro") && siblingText.includes("credits 0"), "window reset hid quota metadata");
await independentlyExpiring.emit("session_shutdown", { reason: "quit" });
assert(siblingClock.tasks.size === 0, "independent window expiry leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const countdownStart = Date.now();
const countdownClock = new FakeClock(countdownStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(countdownStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(150_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  countdownStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const idleCountdown = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => countdownClock.nowMs,
  timers: countdownClock.timers,
}));
await idleCountdown.emit("session_start", { reason: "startup" });
await waitFor(
  () => idleCountdown.widgetText(400).includes("week 94% left reset 3m"),
  `idle-countdown fixture did not publish its initial reset: ${idleCountdown.widgetText(400)}`,
);
const writesBeforeCountdownTransition = idleCountdown.widgetWriteCount;
countdownClock.advance(29_999);
assert(
  idleCountdown.widgetWriteCount === writesBeforeCountdownTransition,
  "reset countdown redrew before its display transition",
);
countdownClock.advance(1);
assert(
  idleCountdown.widgetWriteCount > writesBeforeCountdownTransition,
  "idle reset countdown did not request a redraw at its display transition",
);
assert(
  idleCountdown.widgetText(400).includes("week 94% left reset 2m"),
  `idle reset countdown remained stale: ${idleCountdown.widgetText(400)}`,
);
await idleCountdown.emit("session_shutdown", { reason: "quit" });
assert(countdownClock.tasks.size === 0, "idle reset countdown leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const delayedCountdownStart = Date.now();
const delayedCountdownClock = new SplitClock(delayedCountdownStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(delayedCountdownStart);
process.env.FM_QUOTA_TEST_FIRST_RESET_MS = String(150_000);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  delayedCountdownStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const delayedCountdown = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => delayedCountdownClock.wallNowMs,
  monotonicNow: () => delayedCountdownClock.timerNowMs,
  timers: delayedCountdownClock.timers,
}));
await delayedCountdown.emit("session_start", { reason: "startup" });
await waitFor(
  () => delayedCountdown.widgetText(400).includes("week 94% left reset 3m"),
  "delayed-countdown fixture did not publish its reset window",
);
delayedCountdownClock.wallNowMs = delayedCountdownStart + 180_000;
delayedCountdownClock.advanceTimersDelayed(180_000);
assert(
  !delayedCountdown.widgetText(400).includes("week 94% left"),
  "delayed countdown callback retained an expired quota window",
);
delayedCountdownClock.wallNowMs = delayedCountdownStart + 120_000;
assert(
  !delayedCountdown.widgetText(400).includes("week 94% left"),
  "wall-clock rollback resurrected a monotonically expired quota window",
);
assert(
  delayedCountdown.widgetText(400).includes("GPT-5.3-Codex-Spark session 100% left"),
  "delayed countdown expiry hid a fresh sibling window",
);
await delayedCountdown.emit("session_shutdown", { reason: "quit" });
assert(delayedCountdownClock.tasks.size === 0, "delayed-countdown expiry leaked a timer");
delete process.env.FM_QUOTA_TEST_FIRST_RESET_MS;
delete process.env.FM_QUOTA_TEST_NOW_MS;

const staleFallbackStart = Date.now();
const staleFallbackClock = new FakeClock(staleFallbackStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(staleFallbackStart);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  staleFallbackStart + 24 * 60 * 60 * 1000,
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");
const staleFallback = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => staleFallbackClock.nowMs,
  timers: staleFallbackClock.timers,
}));
await staleFallback.emit("session_start", { reason: "startup" });
await waitFor(
  () => staleFallback.widgetText(400).includes("week 94% left"),
  "stale-fallback fixture did not publish fresh quota",
);
process.env.FM_QUOTA_TEST_STALE_REFRESHED_AT = new Date(staleFallbackStart).toISOString();
process.env.FM_QUOTA_TEST_NOW_MS = String(staleFallbackStart + 5 * 60 * 1000);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "stale_timeout\n");
staleFallbackClock.advance(5 * 60 * 1000);
await waitFor(
  () => staleFallback.widgetText(400).includes("quota-axi timed out"),
  `stale fallback did not expose its timeout: ${staleFallback.widgetText(400)}`,
);
assert(
  staleFallback.widgetText(400).includes("week 94% left"),
  "stale fallback discarded independently fresh cached quota",
);
staleFallbackClock.advance(60 * 1000);
assert(staleFallback.widgetText(400).includes("quota-axi timed out"), "cached expiry hid the stale-fallback timeout");
assert(!staleFallback.widgetText(400).includes("94%"), "cached quota survived its independent freshness deadline");
await staleFallback.emit("session_shutdown", { reason: "quit" });
assert(staleFallbackClock.tasks.size === 0, "stale-fallback shutdown leaked a timer");
delete process.env.FM_QUOTA_TEST_STALE_REFRESHED_AT;
delete process.env.FM_QUOTA_TEST_NOW_MS;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");

const malformedRefreshStart = Date.now();
const malformedRefreshClock = new FakeClock(malformedRefreshStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(malformedRefreshStart);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  malformedRefreshStart + 24 * 60 * 60 * 1000,
);
const malformedRefresh = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => malformedRefreshClock.nowMs,
  timers: malformedRefreshClock.timers,
}));
await malformedRefresh.emit("session_start", { reason: "startup" });
await waitFor(
  () => malformedRefresh.widgetText(400).includes("week 94% left"),
  "malformed-refresh fixture did not publish fresh quota",
);
await writeFile(process.env.FM_QUOTA_TEST_MODE, "malformed\n");
malformedRefreshClock.advance(5 * 60 * 1000);
await waitFor(
  () => malformedRefresh.widgetText(400).includes("malformed data"),
  `malformed refresh was not exposed beside cached quota: ${malformedRefresh.widgetText(400)}`,
);
assert(
  malformedRefresh.widgetText(400).includes("week 94% left"),
  "malformed refresh discarded independently fresh quota",
);
malformedRefreshClock.advance(60 * 1000);
assert(!malformedRefresh.widgetText(400).includes("94%"), "malformed refresh kept quota beyond cache expiry");
assert(malformedRefresh.widgetText(400).includes("malformed data"), "cache expiry hid malformed refresh outcome");
await malformedRefresh.emit("session_shutdown", { reason: "quit" });
assert(malformedRefreshClock.tasks.size === 0, "malformed-refresh shutdown leaked a timer");
delete process.env.FM_QUOTA_TEST_NOW_MS;
await writeFile(process.env.FM_QUOTA_TEST_MODE, "success\n");

const unverifiedRefreshStart = Date.now();
const unverifiedRefreshClock = new FakeClock(unverifiedRefreshStart);
process.env.FM_QUOTA_TEST_NOW_MS = String(unverifiedRefreshStart);
await setStoredOAuth(
  "openai-codex",
  fixtureAccessToken("fixture-codex-account"),
  unverifiedRefreshStart + 24 * 60 * 60 * 1000,
);
const unverifiedRefresh = makePi(createFirstmateQuotaStatusExtension({
  refreshMs: 5 * 60 * 1000,
  freshnessMs: 6 * 60 * 1000,
  timeoutMs: 500,
  now: () => unverifiedRefreshClock.nowMs,
  timers: unverifiedRefreshClock.timers,
}));
await unverifiedRefresh.emit("session_start", { reason: "startup" });
await waitFor(
  () => unverifiedRefresh.widgetText(400).includes("week 94% left"),
  "unverified-refresh fixture did not publish initial account quota",
);
process.env.FM_QUOTA_TEST_CODEX_ACCOUNT_ID = "independent-codex-account";
process.env.FM_QUOTA_TEST_NOW_MS = String(unverifiedRefreshStart + 5 * 60 * 1000);
unverifiedRefreshClock.advance(5 * 60 * 1000);
await waitFor(
  () => unverifiedRefresh.widgetText(400).includes("account unverified"),
  `unverified refresh was not exposed beside cached quota: ${unverifiedRefresh.widgetText(400)}`,
);
assert(
  unverifiedRefresh.widgetText(400).includes("week 94% left"),
  "unverified refresh discarded independently fresh account quota",
);
unverifiedRefreshClock.advance(60 * 1000);
assert(!unverifiedRefresh.widgetText(400).includes("94%"), "unverified refresh kept quota beyond cache expiry");
assert(unverifiedRefresh.widgetText(400).includes("account unverified"), "cache expiry hid unverified refresh outcome");
await unverifiedRefresh.emit("session_shutdown", { reason: "quit" });
assert(unverifiedRefreshClock.tasks.size === 0, "unverified-refresh shutdown leaked a timer");
delete process.env.FM_QUOTA_TEST_CODEX_ACCOUNT_ID;
delete process.env.FM_QUOTA_TEST_NOW_MS;

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
fakeClock.jump(-60 * 1000);
assert(expiring.widgetText(400).includes("quota-axi failed"), "clock recovery hid the failed refresh outcome");
assert(
  expiring.widgetText(400).includes("week 94% left"),
  "transient forward clock jump tombstoned quota before its authoritative expiry",
);
fakeClock.jump(60 * 1000);
fakeClock.advance(0);
assert(expiring.widgetWriteCount > writesBeforeDelayedExpiry, "expiry callback did not republish the failed refresh view");
assert(!expiring.widgetText(400).includes("94%"), "expiry callback retained expired quota values");
fakeClock.jump(-60 * 1000);
assert(!expiring.widgetText(400).includes("94%"), "authoritatively expired quota values resurrected");
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

await setStoredOAuth("openai-codex", fixtureAccessToken(null));
const callsBeforeMissingIdentity = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
const missingCodexIdentity = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
);
await missingCodexIdentity.emit("session_start", { reason: "startup" });
await waitFor(
  () => missingCodexIdentity.widgetText(240).includes("account correlation unavailable"),
  `missing active account identity was not classified before refresh: ${missingCodexIdentity.widgetText(240)}`,
);
await sleep(30);
const callsAfterMissingIdentity = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(callsAfterMissingIdentity === callsBeforeMissingIdentity, "missing Codex identity invoked quota-axi");
await missingCodexIdentity.emit("session_shutdown", { reason: "quit" });

await setStoredOAuth("openai-codex", fixtureAccessToken("other-codex-account"));
const differentCodexAccount = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
);
await differentCodexAccount.emit("session_start", { reason: "startup" });
await waitFor(
  () => differentCodexAccount.widgetText(240).includes("account unverified"),
  `different active account was not refused: ${differentCodexAccount.widgetText(240)}`,
);
assert(!differentCodexAccount.widgetText(400).includes("94%"), "different active account exposed unrelated fresh quota");
await differentCodexAccount.emit("session_shutdown", { reason: "quit" });
await setStoredOAuth("openai-codex", fixtureAccessToken("fixture-codex-account"));

await setStoredOAuth("openai-codex", fixtureAccessToken("replacement-codex-account", {
  "https://api.openai.com/auth/account_id": "fixture-codex-account",
}));
const callsBeforeConflictingClaims = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
const conflictingCodexClaims = makePi(
  createFirstmateQuotaStatusExtension({ refreshMs: 60_000, timeoutMs: 500 }),
  "openai-codex",
);
await conflictingCodexClaims.emit("session_start", { reason: "startup" });
await waitFor(
  () => conflictingCodexClaims.widgetText(240).includes("account correlation unavailable"),
  `conflicting Codex account claims were accepted: ${conflictingCodexClaims.widgetText(240)}`,
);
assert(!conflictingCodexClaims.widgetText(400).includes("94%"), "legacy Codex claim overrode Pi's active account");
const callsAfterConflictingClaims = (await readFile(process.env.FM_QUOTA_TEST_CALLS, "utf8"))
  .trim()
  .split(/\n/)
  .filter(Boolean).length;
assert(callsAfterConflictingClaims === callsBeforeConflictingClaims, "conflicting Codex identity invoked quota-axi");
await conflictingCodexClaims.emit("session_shutdown", { reason: "quit" });
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
await statusCase("structured_timeout", "quota-axi timed out");
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
