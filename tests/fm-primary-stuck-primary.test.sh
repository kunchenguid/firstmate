#!/usr/bin/env bash
# Unit tests for post-arm stuck-primary recovery heuristics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/.pi/extensions/lib/fm-primary-stuck-primary.ts"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-stuck-primary.XXXXXX")
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

STATE="$TMP_HOME/state"
mkdir -p "$STATE"
printf 'window=1\n' >"$STATE/task-1.meta"
printf 'epoch\t1\tsignal\ttask-1\tdone\n' >"$STATE/.wake-queue"

FM_STATE_OVERRIDE="$STATE" FM_PI_STUCK_AFTER_ARM_MS=10000 LIB="$LIB" \
  node --experimental-strip-types --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
const {
  createStuckPrimaryMonitor,
  parseStuckAfterArmMs,
  wakeQueueHasRecords,
  hasInFlightFleetWork,
} = await import(pathToFileURL(process.env.LIB).href);

const stateDir = process.env.FM_STATE_OVERRIDE;
const fail = (message) => {
  console.error(`not ok - ${message}`);
  process.exit(1);
};

if (parseStuckAfterArmMs(undefined) !== 45000) fail("default stuck-after-arm ms");
if (parseStuckAfterArmMs("12000") !== 12000) fail("parsed stuck-after-arm ms");
if (parseStuckAfterArmMs("1") !== 45000) fail("reject tiny stuck-after-arm ms");
if (parseStuckAfterArmMs("200") !== 200) fail("accept test stuck-after-arm ms");
if (!wakeQueueHasRecords(stateDir)) fail("wake queue should be readable");
if (!hasInFlightFleetWork(stateDir)) fail("meta file should count as in-flight work");

const monitor = createStuckPrimaryMonitor({ stateDir, stuckAfterArmMs: 10_000 });
const t0 = 1_000_000;
const probeBusy = { isIdle: () => false, hasPendingMessages: () => true };
const probeIdle = { isIdle: () => true, hasPendingMessages: () => true };
const probeQuiet = { isIdle: () => false, hasPendingMessages: () => false };

monitor.onAgentStart(t0);
if (monitor.recoveryAction(probeBusy, t0 + 20_000) !== "none") fail("no recovery before watcher arm");

monitor.onWatcherArmSucceeded(t0 + 1_000);
if (monitor.recoveryAction(probeBusy, t0 + 5_000) !== "none") fail("no recovery before stall window");

const quietState = `${stateDir}-quiet`;
mkdirSync(quietState, { recursive: true });
writeFileSync(`${quietState}/task-2.meta`, "window=2\n");
const quietMonitor = createStuckPrimaryMonitor({ stateDir: quietState, stuckAfterArmMs: 10_000 });
quietMonitor.onAgentStart(t0);
quietMonitor.onWatcherArmSucceeded(t0 + 1_000);
if (quietMonitor.recoveryAction(probeQuiet, t0 + 20_000) !== "none") fail("no recovery without backpressure");
if (monitor.recoveryAction(probeBusy, t0 + 20_000) !== "none") fail("busy stall must not abort or trigger turn");

monitor.onAgentStart(t0);
monitor.onWatcherArmSucceeded(t0 + 1_000);
if (monitor.recoveryAction(probeIdle, t0 + 20_000) !== "triggerTurn") fail("idle stall with backlog should trigger turn");

monitor.onAgentStart(t0);
monitor.onWatcherArmSucceeded(t0 + 1_000);
monitor.onProgress(t0 + 15_000);
if (monitor.recoveryAction(probeBusy, t0 + 20_000) !== "none") fail("recent progress should suppress recovery");

monitor.onAgentStart(t0);
monitor.onWatcherArmSucceeded(t0 + 1_000);
monitor.recoveryAction(probeBusy, t0 + 20_000);
monitor.markRecoveryAttempted();
if (monitor.recoveryAction(probeBusy, t0 + 40_000) !== "none") fail("recovery cooldown should suppress repeats");

console.log("ok - stuck-primary recovery heuristics");
EOF
