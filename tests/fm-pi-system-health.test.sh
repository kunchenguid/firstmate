#!/usr/bin/env bash
# Public-interface behavior tests for the Pi system-health status extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot fm-pi-system-health >/dev/null
EXT="$ROOT/.pi/extensions/fm-system-health.ts"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

out=$(EXT="$EXT" node --input-type=module 2>&1 <<'JS'
const mod = await import(process.env.EXT);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, message) {
  assert(Object.is(actual, expected), `${message}: expected ${expected}, got ${actual}`);
}

function assertNear(actual, expected, message) {
  assert(actual !== undefined && Math.abs(actual - expected) < 0.0001, `${message}: expected ${expected}, got ${actual}`);
}

const cpu = (times) => ({ times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0, ...times } });
const firstCpu = mod.captureCpuSnapshot([cpu({ user: 50, sys: 20, idle: 30 })]);
const secondCpu = mod.captureCpuSnapshot([cpu({ user: 70, sys: 30, idle: 50 })]);

assertEqual(mod.calculateMemoryFreePercent(1000, 250), 25, "memory percentage calculation");
assertEqual(mod.calculateMemoryFreePercent(0, 250), undefined, "zero total memory is unavailable");
assertEqual(mod.calculateMemoryFreePercent(1000, 1200), undefined, "impossible free memory is unavailable");
assertNear(mod.calculateCpuUtilization(firstCpu, secondCpu), 60, "CPU delta calculation");
assertEqual(mod.calculateCpuUtilization(undefined, secondCpu), undefined, "first CPU sample is unavailable");
assertEqual(mod.calculateCpuUtilization(firstCpu, { idle: 1, total: 1 }), undefined, "counter reset is unavailable");

const sampled = mod.sampleHealthSources(
  { totalMemoryBytes: 200, freeMemoryBytes: 50, cpus: [cpu({ user: 70, sys: 30, idle: 50 })] },
  firstCpu,
);
assertNear(sampled.metrics.memoryFreePercent, 25, "sampled memory percentage");
assertNear(sampled.metrics.cpuUtilizationPercent, 60, "sampled CPU percentage");

assertEqual(mod.metricTone("memory", 25), "muted", "healthy memory tone");
assertEqual(mod.metricTone("memory", 19), "warning", "low memory tone");
assertEqual(mod.metricTone("memory", 9), "error", "critical memory tone");
assertEqual(mod.metricTone("cpu", 69), "muted", "healthy CPU tone");
assertEqual(mod.metricTone("cpu", 70), "warning", "busy CPU tone");
assertEqual(mod.metricTone("cpu", 90), "error", "critical CPU tone");

const theme = { fg: (color, text) => `<${color}>${text}</${color}>` };
const compact = mod.formatHealthStatus(sampled.metrics);
assertEqual(compact, "RAM 25% free · CPU 60%", "compact status rendering");
assert(compact.length <= 32, `status should stay compact: ${compact}`);
const styled = mod.renderHealthStatus(sampled.metrics, theme);
assert(styled.includes("<muted>RAM 25% free</muted>"), `memory status lost calm styling: ${styled}`);
assert(styled.includes("<muted>CPU 60%</muted>"), `CPU status lost calm styling: ${styled}`);
assertEqual(mod.renderHealthStatus({}, theme), "", "unavailable metrics render no unsupported values");
assertEqual(
  mod.formatHealthReport({}),
  "System health: no supported metrics available",
  "unavailable metrics report",
);
const unavailable = mod.sampleHealthSources({ totalMemoryBytes: 0, freeMemoryBytes: 0, cpus: [] });
assertEqual(Object.keys(unavailable.metrics).length, 0, "unavailable sources stay absent");

const nativeSetInterval = globalThis.setInterval;
const nativeClearInterval = globalThis.clearInterval;
const intervals = [];
const cleared = [];
globalThis.setInterval = (callback, delay) => {
  const handle = { callback, delay, cleared: false, unrefCalled: false };
  handle.unref = () => { handle.unrefCalled = true; };
  intervals.push(handle);
  return handle;
};
globalThis.clearInterval = (handle) => {
  handle.cleared = true;
  cleared.push(handle);
};

const handlers = new Map();
let command;
let footerCalls = 0;
const statuses = [];
const notices = [];
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
  registerCommand(name, definition) {
    if (name === "system-health") command = definition;
  },
  registerTool() {
    throw new Error("system-health must not register an LLM tool");
  },
};
mod.default(pi);
assertEqual(intervals.length, 0, "sampler starts only at session_start");
assert(command, "slash command was registered");
assert(handlers.has("session_start"), "session_start handler was registered");
assert(handlers.has("session_shutdown"), "session_shutdown handler was registered");

const context = {
  mode: "tui",
  hasUI: true,
  ui: {
    theme,
    setStatus(key, text) {
      statuses.push({ key, text });
    },
    setFooter() {
      footerCalls += 1;
    },
    notify(message, type) {
      notices.push({ message, type });
    },
  },
};

await handlers.get("session_start")({ reason: "startup" }, context);
assertEqual(intervals.length, 1, "session_start starts one sampler");
assertEqual(intervals[0].delay, mod.SYSTEM_HEALTH_REFRESH_MS, "sampler uses bounded cadence");
assert(intervals[0].unrefCalled, "sampler does not keep Pi alive");
assert(statuses.some((entry) => entry.key === mod.SYSTEM_HEALTH_STATUS_KEY), "status uses the unique health key");

await handlers.get("session_start")({ reason: "reload" }, context);
assertEqual(intervals.length, 2, "reload creates one replacement sampler");
assert(intervals[0].cleared, "reload clears the previous sampler");
assertEqual(intervals.filter((entry) => !entry.cleared).length, 1, "reload does not leak duplicate samplers");

const statusCountBeforeTick = statuses.length;
intervals[1].callback();
assert(statuses.length > statusCountBeforeTick, "timer refresh publishes status");

await command.handler("off", context);
assertEqual(statuses.at(-1).text, undefined, "off clears only the extension status");
await command.handler("on", context);
assertEqual(notices.at(-1).type, "info", "on reports through the slash command");
await command.handler("show", context);
assert(notices.at(-1).message.startsWith("System health:"), "show reports current values");
assertEqual(footerCalls, 0, "built-in footer is never replaced");

await handlers.get("session_shutdown")({ reason: "reload" }, context);
assert(intervals[1].cleared, "session_shutdown clears the active sampler");
assertEqual(intervals.filter((entry) => !entry.cleared).length, 0, "shutdown leaves no sampler");
const statusCountAfterShutdown = statuses.length;
intervals[1].callback();
assertEqual(statuses.length, statusCountAfterShutdown, "late timer callbacks are inert after shutdown");

globalThis.setInterval = nativeSetInterval;
globalThis.clearInterval = nativeClearInterval;
JS
)
status=$?
expect_code 0 "$status" "Pi system-health public-interface behavior tests"
[ -z "$out" ] || fail "Pi system-health tests printed output: $out"
pass "Pi system-health metrics, rendering, lifecycle cleanup, unavailable sources, and footer preservation"
