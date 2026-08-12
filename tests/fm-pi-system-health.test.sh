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

function toneOf(styled, label) {
  const match = new RegExp(`<([a-z]+)>${label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}</`).exec(styled);
  assert(match, `expected a styled "${label}" segment in ${styled}`);
  return match[1];
}

for (const [rawA, rawB, label, tone] of [
  [9.6, 10.4, "RAM 10% free", "warning"],
  [19.6, 20.4, "RAM 20% free", "muted"],
  [8.6, 9.4, "RAM 9% free", "error"],
]) {
  const first = mod.renderHealthStatus({ memoryFreePercent: rawA }, theme);
  const second = mod.renderHealthStatus({ memoryFreePercent: rawB }, theme);
  assertEqual(first, second, `memory boundary ${rawA}/${rawB} must render identically`);
  assertEqual(toneOf(first, label), tone, `memory boundary tone for "${label}"`);
}

for (const [rawA, rawB, label, tone] of [
  [69.6, 70.4, "CPU 70%", "warning"],
  [89.6, 90.4, "CPU 90%", "error"],
  [68.6, 69.4, "CPU 69%", "muted"],
]) {
  const first = mod.renderHealthStatus({ cpuUtilizationPercent: rawA }, theme);
  const second = mod.renderHealthStatus({ cpuUtilizationPercent: rawB }, theme);
  assertEqual(first, second, `CPU boundary ${rawA}/${rawB} must render identically`);
  assertEqual(toneOf(first, label), tone, `CPU boundary tone for "${label}"`);
}

for (const raw of [9.6, 10.4, 19.6, 20.4]) {
  assert(
    mod.renderHealthStatus({ memoryFreePercent: raw }, theme).includes(
      `RAM ${mod.displayedPercent(raw)}% free`,
    ),
    `styled memory label must match the compact label for ${raw}`,
  );
}
for (const raw of [69.6, 70.4, 89.6, 90.4]) {
  assertEqual(
    mod.formatHealthStatus({ cpuUtilizationPercent: raw }),
    `CPU ${mod.displayedPercent(raw)}%`,
    `compact CPU label for ${raw}`,
  );
}
assertEqual(
  mod.formatHealthReport({}),
  "System health: no supported metrics available",
  "unavailable metrics report",
);
const unavailable = mod.sampleHealthSources({ totalMemoryBytes: 0, freeMemoryBytes: 0, cpus: [] });
assertEqual(Object.keys(unavailable.metrics).length, 0, "unavailable sources stay absent");

// macOS memory availability: parsing real vm_stat output and deriving the percentage
// the operating system itself reports, rather than the wholly-unused-page ratio.
const vmStatSample = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    21405.
Pages active:                                 501482.
Pages inactive:                               471564.
Pages speculative:                             31359.
Pages throttled:                                   0.
Pages wired down:                             274568.
Pages purgeable:                               16774.
File-backed pages:                            325436.
Anonymous pages:                              678969.
Pages occupied by compressor:                 233146.
Pageins:                                   104187920.`;

const counts = mod.parseVmStat(vmStatSample);
assertEqual(counts.pageSizeBytes, 16384, "vm_stat page size parsing");
assertEqual(counts.wired, 274568, "vm_stat wired page parsing");
assertEqual(counts.compressorOccupied, 233146, "vm_stat compressor page parsing");
assertEqual(mod.parseVmStat(""), undefined, "empty vm_stat output is unavailable");
assertEqual(mod.parseVmStat(undefined), undefined, "missing vm_stat output is unavailable");
assertEqual(
  mod.parseVmStat("Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1."),
  undefined,
  "vm_stat output missing required counters is unavailable",
);

// 24 GiB across 16 KiB pages is 1572864 pages; 274568 wired + 233146 compressed are
// unavailable, leaving ~67.7% available, matching what macOS reports for this sample.
const totalBytes = 25769803776;
assertNear(
  mod.calculateMacOsAvailableMemoryPercent(counts, totalBytes),
  ((1572864 - 274568 - 233146) / 1572864) * 100,
  "macOS available memory percentage",
);
assertEqual(mod.displayedPercent(mod.calculateMacOsAvailableMemoryPercent(counts, totalBytes)), 68,
  "macOS available memory rounds to the OS-reported percentage");
assertEqual(mod.metricTone("memory", 68), "muted", "an unstressed Mac renders a calm tone");
assertEqual(
  mod.calculateMacOsAvailableMemoryPercent(counts, 0),
  undefined,
  "unknown total memory makes macOS availability unavailable",
);
assertEqual(
  mod.calculateMacOsAvailableMemoryPercent(undefined, totalBytes),
  undefined,
  "absent vm_stat counts make macOS availability unavailable",
);
assertEqual(
  mod.calculateMacOsAvailableMemoryPercent(
    { pageSizeBytes: 16384, wired: 9e9, compressorOccupied: 0 },
    totalBytes,
  ),
  undefined,
  "impossible page counts are unavailable rather than clamped",
);

// The macOS source supersedes os.freemem(): the same host that looks 1% free by
// wholly-unused pages is reported at its true availability.
const macSample = mod.sampleHealthSources({
  totalMemoryBytes: totalBytes,
  freeMemoryBytes: Math.round(totalBytes * 0.01),
  isMacOs: true,
  vmStat: counts,
});
assertEqual(mod.displayedPercent(macSample.metrics.memoryFreePercent), 68,
  "vm_stat availability supersedes the misleading free-memory ratio");
assertEqual(
  mod.metricTone("memory", mod.displayedPercent(macSample.metrics.memoryFreePercent)),
  "muted",
  "a healthy Mac is not shown as critical",
);

// Off macOS the portable free-memory ratio is truthful and is still used.
const portableSample = mod.sampleHealthSources({ totalMemoryBytes: 1000, freeMemoryBytes: 250 });
assertNear(portableSample.metrics.memoryFreePercent, 25, "non-macOS memory stays os.freemem based");

// On macOS a failed vm_stat omits the memory metric rather than falling back to the
// misleading free-memory ratio, while the CPU metric remains available.
const macWithoutVmStat = mod.sampleHealthSources(
  {
    totalMemoryBytes: totalBytes,
    freeMemoryBytes: Math.round(totalBytes * 0.01),
    isMacOs: true,
    vmStat: undefined,
    cpus: [cpu({ user: 70, sys: 30, idle: 50 })],
  },
  firstCpu,
);
assertEqual(
  macWithoutVmStat.metrics.memoryFreePercent,
  undefined,
  "an unreadable macOS memory source omits the metric instead of guessing",
);
assertNear(macWithoutVmStat.metrics.cpuUtilizationPercent, 60, "CPU survives an unreadable memory source");
assertEqual(
  mod.formatHealthStatus(macWithoutVmStat.metrics),
  "CPU 60%",
  "only truthful supported metrics are shown",
);

assertEqual(await mod.readVmStat("linux"), undefined, "vm_stat is not invoked off macOS");

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

// Sampling is asynchronous because the macOS memory source is a bounded subprocess,
// so a refresh publishes once the in-flight sample settles rather than inline.
const settle = async () => {
  for (let i = 0; i < 50; i += 1) await new Promise((resolve) => setImmediate(resolve));
};

await handlers.get("session_start")({ reason: "startup" }, context);
await settle();
assertEqual(intervals.length, 1, "session_start starts one sampler");
assertEqual(intervals[0].delay, mod.SYSTEM_HEALTH_REFRESH_MS, "sampler uses bounded cadence");
assert(intervals[0].unrefCalled, "sampler does not keep Pi alive");
assert(statuses.some((entry) => entry.key === mod.SYSTEM_HEALTH_STATUS_KEY), "status uses the unique health key");

await handlers.get("session_start")({ reason: "reload" }, context);
await settle();
assertEqual(intervals.length, 2, "reload creates one replacement sampler");
assert(intervals[0].cleared, "reload clears the previous sampler");
assertEqual(intervals.filter((entry) => !entry.cleared).length, 1, "reload does not leak duplicate samplers");

const statusCountBeforeTick = statuses.length;
intervals[1].callback();
await settle();
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
await settle();
assertEqual(statuses.length, statusCountAfterShutdown, "late timer callbacks are inert after shutdown");

globalThis.setInterval = nativeSetInterval;
globalThis.clearInterval = nativeClearInterval;
JS
)
status=$?
expect_code 0 "$status" "Pi system-health public-interface behavior tests"
[ -z "$out" ] || fail "Pi system-health tests printed output: $out"
pass "Pi system-health metrics, rendering, lifecycle cleanup, unavailable sources, and footer preservation"

# The tone assertions above use synthetic percentages, so they cannot show what
# the Captain actually sees on a Mac. This exercises the live sampling path end to
# end and compares the displayed value and tone against the availability accounting
# reported by macOS, covering both truthfulness and the calm-default rule.
if [ "$(uname -s)" = "Darwin" ] && command -v memory_pressure >/dev/null 2>&1; then
  os_free_percent=$(memory_pressure 2>/dev/null |
    sed -n 's/.*[Ff]ree percentage: *\([0-9][0-9]*\)%.*/\1/p' | tail -1)
  if [ -n "$os_free_percent" ]; then
    health_out=$(EXT="$EXT" OS_FREE_PERCENT="$os_free_percent" node --input-type=module 2>&1 <<'JS'
const mod = await import(process.env.EXT);
const osFreePercent = Number(process.env.OS_FREE_PERCENT);

// macOS reports memory as unstressed, so the indicator must read calm too.
if (osFreePercent < 40) {
  console.log(`skip: host is genuinely low on memory (${osFreePercent}% free)`);
  process.exit(0);
}

const { metrics } = await mod.sampleCurrentHealth();
if (metrics.memoryFreePercent === undefined) {
  console.error("system-health reported no memory metric on a Mac where vm_stat is available");
  process.exit(1);
}
const shown = mod.displayedPercent(metrics.memoryFreePercent);
const tone = mod.metricTone("memory", shown);
if (tone !== "muted") {
  console.error(
    `system-health shows "RAM ${shown}% free" in "${tone}" tone while macOS reports ` +
      `${osFreePercent}% memory free; an unstressed Mac must render calm`,
  );
  process.exit(1);
}

// The displayed value must track the accounting macOS itself reports, not merely
// look calm. memory_pressure truncates and samples a moment apart, so allow drift.
if (Math.abs(shown - osFreePercent) > 8) {
  console.error(
    `system-health reports ${shown}% available while macOS reports ${osFreePercent}%; ` +
      "the memory metric must reflect the availability accounting reported by macOS",
  );
  process.exit(1);
}
JS
    )
    health_status=$?
    case "$health_out" in
      skip:*) echo "$health_out" ;;
      *)
        expect_code 0 "$health_status" "live macOS memory reading stays calm when the OS reports memory free"
        [ -z "$health_out" ] || fail "$health_out"
        pass "live macOS memory reading renders a calm tone on an unstressed host"
        ;;
    esac
  fi
fi
