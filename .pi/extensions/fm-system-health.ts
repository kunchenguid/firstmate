// Firstmate's compact Pi system-health status.
//
// The extension reports available RAM and sampled aggregate CPU utilization only.
//
// Memory semantics are platform-specific on purpose. Node's `os.freemem()` reports
// only wholly unused pages, which on macOS excludes the inactive, speculative, and
// purgeable pages the OS itself counts as available. Reporting that number would
// show a single-digit percentage on an idle Mac while macOS reports two thirds free.
// On macOS the extension therefore derives available memory from `vm_stat` page
// counts, matching the OS view within rounding. Elsewhere `os.freemem()` is truthful
// and is used directly. The `vm_stat` call is a bounded, cached subprocess run only
// from the sampler at its fixed cadence, never from render() or a repaint.
import * as os from "node:os";
import { execFile } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const SYSTEM_HEALTH_STATUS_KEY = "firstmate-system-health";
export const SYSTEM_HEALTH_REFRESH_MS = 3_000;
export const SYSTEM_HEALTH_VM_STAT_TIMEOUT_MS = 1_000;

export type CpuTimesLike = {
  user: number;
  nice: number;
  sys: number;
  idle: number;
  irq: number;
};

export type CpuInfoLike = {
  times: CpuTimesLike;
};

export type CpuSnapshot = {
  idle: number;
  total: number;
};

export type HealthMetrics = {
  memoryFreePercent?: number;
  cpuUtilizationPercent?: number;
};

export type HealthSources = {
  totalMemoryBytes?: number;
  freeMemoryBytes?: number;
  cpus?: readonly CpuInfoLike[];
  // When true the macOS availability rules apply and `freeMemoryBytes` is ignored,
  // because `os.freemem()` is not a truthful availability signal on that platform.
  isMacOs?: boolean;
  // Parsed `vm_stat` counters; absent when the source could not be read.
  vmStat?: VmStatPageCounts;
};

export type HealthTone = "muted" | "warning" | "error";
export type MetricKind = "memory" | "cpu";
export type HealthTheme = Pick<ExtensionContext["ui"]["theme"], "fg">;

// The subset of `vm_stat` page counters needed to describe macOS memory availability.
export type VmStatPageCounts = {
  pageSizeBytes: number;
  wired: number;
  compressorOccupied: number;
};

function boundedPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function parseVmStatCounter(text: string, label: string): number | undefined {
  // vm_stat prints "Pages wired down:      274568." — a trailing period, and the
  // label itself may contain regex-significant characters in future macOS versions.
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`^${escaped}:\\s*(\\d+)\\.?\\s*$`, "m").exec(text);
  if (!match) return undefined;
  const value = Number(match[1]);
  return Number.isFinite(value) && value >= 0 ? value : undefined;
}

export function parseVmStat(text: string | undefined): VmStatPageCounts | undefined {
  if (!text) return undefined;
  const pageSizeMatch = /page size of (\d+) bytes/.exec(text);
  const pageSizeBytes = pageSizeMatch ? Number(pageSizeMatch[1]) : undefined;
  const wired = parseVmStatCounter(text, "Pages wired down");
  const compressorOccupied = parseVmStatCounter(text, "Pages occupied by compressor");
  if (
    pageSizeBytes === undefined ||
    !Number.isFinite(pageSizeBytes) ||
    pageSizeBytes <= 0 ||
    wired === undefined ||
    compressorOccupied === undefined
  ) {
    return undefined;
  }
  return { pageSizeBytes, wired, compressorOccupied };
}

// macOS treats wired and compressor-occupied pages as genuinely unavailable; active,
// inactive, speculative, and purgeable pages are all reclaimable and are counted as
// available by the OS. This mirrors the percentage `memory_pressure` reports.
export function calculateMacOsAvailableMemoryPercent(
  counts: VmStatPageCounts | undefined,
  totalMemoryBytes: number | undefined,
): number | undefined {
  if (
    !counts ||
    totalMemoryBytes === undefined ||
    !Number.isFinite(totalMemoryBytes) ||
    totalMemoryBytes <= 0
  ) {
    return undefined;
  }
  const totalPages = totalMemoryBytes / counts.pageSizeBytes;
  if (!Number.isFinite(totalPages) || totalPages <= 0) return undefined;
  const unavailablePages = counts.wired + counts.compressorOccupied;
  if (!Number.isFinite(unavailablePages) || unavailablePages < 0) return undefined;
  if (unavailablePages > totalPages) return undefined;
  return boundedPercent(((totalPages - unavailablePages) / totalPages) * 100);
}

export function calculateMemoryFreePercent(
  totalMemoryBytes: number | undefined,
  freeMemoryBytes: number | undefined,
): number | undefined {
  if (
    totalMemoryBytes === undefined ||
    freeMemoryBytes === undefined ||
    !Number.isFinite(totalMemoryBytes) ||
    !Number.isFinite(freeMemoryBytes) ||
    totalMemoryBytes <= 0 ||
    freeMemoryBytes < 0 ||
    freeMemoryBytes > totalMemoryBytes
  ) {
    return undefined;
  }
  return boundedPercent((freeMemoryBytes / totalMemoryBytes) * 100);
}

export function captureCpuSnapshot(
  cpus: readonly CpuInfoLike[] | undefined,
): CpuSnapshot | undefined {
  if (!cpus || cpus.length === 0) return undefined;

  let idle = 0;
  let total = 0;
  for (const cpu of cpus) {
    const times = cpu?.times;
    if (!times) return undefined;
    const values = [times.user, times.nice, times.sys, times.idle, times.irq];
    if (values.some((value) => !Number.isFinite(value) || value < 0)) return undefined;
    idle += times.idle;
    total += values.reduce((sum, value) => sum + value, 0);
  }

  if (!Number.isFinite(idle) || !Number.isFinite(total) || total <= 0) return undefined;
  return { idle, total };
}

export function calculateCpuUtilization(
  previous: CpuSnapshot | undefined,
  current: CpuSnapshot | undefined,
): number | undefined {
  if (!previous || !current) return undefined;
  const totalDelta = current.total - previous.total;
  const idleDelta = current.idle - previous.idle;
  if (
    !Number.isFinite(totalDelta) ||
    !Number.isFinite(idleDelta) ||
    totalDelta <= 0 ||
    idleDelta < 0 ||
    idleDelta > totalDelta
  ) {
    return undefined;
  }
  return boundedPercent(((totalDelta - idleDelta) / totalDelta) * 100);
}

export function sampleHealthSources(
  sources: HealthSources,
  previousCpuSnapshot?: CpuSnapshot,
): { metrics: HealthMetrics; cpuSnapshot: CpuSnapshot | undefined } {
  const metrics: HealthMetrics = {};
  // On macOS only the vm_stat-derived availability is truthful, so when that source
  // is missing the memory metric is omitted rather than falling back to the
  // os.freemem() ratio, which would read as near-zero on a healthy Mac.
  const memoryFreePercent = sources.isMacOs
    ? calculateMacOsAvailableMemoryPercent(sources.vmStat, sources.totalMemoryBytes)
    : calculateMemoryFreePercent(sources.totalMemoryBytes, sources.freeMemoryBytes);
  if (memoryFreePercent !== undefined) metrics.memoryFreePercent = memoryFreePercent;

  const cpuSnapshot = captureCpuSnapshot(sources.cpus);
  const cpuUtilizationPercent = calculateCpuUtilization(previousCpuSnapshot, cpuSnapshot);
  if (cpuUtilizationPercent !== undefined) metrics.cpuUtilizationPercent = cpuUtilizationPercent;

  return { metrics, cpuSnapshot };
}

function readOptionalNumber(read: () => number): number | undefined {
  try {
    const value = read();
    return Number.isFinite(value) && value >= 0 ? value : undefined;
  } catch {
    return undefined;
  }
}

function readOptionalCpus(): readonly CpuInfoLike[] | undefined {
  try {
    const cpus = os.cpus();
    return cpus.length > 0 ? cpus : undefined;
  } catch {
    return undefined;
  }
}

// Runs `vm_stat` with a bounded timeout and no shell. Resolves to undefined on any
// failure so an unavailable source degrades to an omitted metric rather than a guess.
export function readVmStat(
  platform: string = process.platform,
  timeoutMs: number = SYSTEM_HEALTH_VM_STAT_TIMEOUT_MS,
): Promise<VmStatPageCounts | undefined> {
  if (platform !== "darwin") return Promise.resolve(undefined);
  return new Promise((resolve) => {
    try {
      execFile(
        "/usr/bin/vm_stat",
        [],
        { timeout: timeoutMs, maxBuffer: 64 * 1024, windowsHide: true },
        (error, stdout) => resolve(error ? undefined : parseVmStat(stdout)),
      );
    } catch {
      resolve(undefined);
    }
  });
}

export async function sampleCurrentHealth(previousCpuSnapshot?: CpuSnapshot): Promise<{
  metrics: HealthMetrics;
  cpuSnapshot: CpuSnapshot | undefined;
}> {
  const isMacOs = process.platform === "darwin";
  const vmStat = await readVmStat();
  return sampleHealthSources(
    {
      totalMemoryBytes: readOptionalNumber(() => os.totalmem()),
      freeMemoryBytes: readOptionalNumber(() => os.freemem()),
      cpus: readOptionalCpus(),
      isMacOs,
      vmStat,
    },
    previousCpuSnapshot,
  );
}

export function metricTone(kind: MetricKind, value: number | undefined): HealthTone {
  if (value === undefined) return "muted";
  const warningThreshold = kind === "memory" ? 20 : 70;
  const errorThreshold = kind === "memory" ? 10 : 90;
  if (kind === "memory") {
    if (value < errorThreshold) return "error";
    if (value < warningThreshold) return "warning";
    return "muted";
  }
  if (value >= errorThreshold) return "error";
  if (value >= warningThreshold) return "warning";
  return "muted";
}

export function displayedPercent(value: number): number {
  return Math.round(boundedPercent(value));
}

export function formatHealthStatus(metrics: HealthMetrics): string {
  const parts: string[] = [];
  if (metrics.memoryFreePercent !== undefined) {
    parts.push(`RAM ${displayedPercent(metrics.memoryFreePercent)}% free`);
  }
  if (metrics.cpuUtilizationPercent !== undefined) {
    parts.push(`CPU ${displayedPercent(metrics.cpuUtilizationPercent)}%`);
  }
  return parts.join(" · ");
}

export function renderHealthStatus(metrics: HealthMetrics, theme: HealthTheme): string {
  const parts: string[] = [];
  if (metrics.memoryFreePercent !== undefined) {
    const shown = displayedPercent(metrics.memoryFreePercent);
    parts.push(theme.fg(metricTone("memory", shown), `RAM ${shown}% free`));
  }
  if (metrics.cpuUtilizationPercent !== undefined) {
    const shown = displayedPercent(metrics.cpuUtilizationPercent);
    parts.push(theme.fg(metricTone("cpu", shown), `CPU ${shown}%`));
  }
  return parts.join(theme.fg("dim", " · "));
}

export function formatHealthReport(metrics: HealthMetrics): string {
  const status = formatHealthStatus(metrics);
  return status ? `System health: ${status}` : "System health: no supported metrics available";
}

export default function systemHealthExtension(pi: ExtensionAPI): void {
  let enabled = true;
  let active = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let previousCpuSnapshot: CpuSnapshot | undefined;
  let latestMetrics: HealthMetrics = {};
  let startGeneration = 0;

  const clearTimer = (ctx?: ExtensionContext): void => {
    active = false;
    startGeneration += 1;
    if (timer !== undefined) clearInterval(timer);
    timer = undefined;
    previousCpuSnapshot = undefined;
    latestMetrics = {};
    ctx?.ui.setStatus(SYSTEM_HEALTH_STATUS_KEY, undefined);
  };

  const publish = (ctx: ExtensionContext): void => {
    const text = enabled ? renderHealthStatus(latestMetrics, ctx.ui.theme) : "";
    ctx.ui.setStatus(SYSTEM_HEALTH_STATUS_KEY, text || undefined);
  };

  // Guards against a slow vm_stat call overlapping the next tick, and against a
  // sample that resolves after shutdown resurrecting a cleared status.
  let sampling = false;

  const sample = async (ctx: ExtensionContext): Promise<void> => {
    if (sampling) return;
    sampling = true;
    const generation = startGeneration;
    try {
      const result = await sampleCurrentHealth(previousCpuSnapshot);
      if (generation !== startGeneration) return;
      previousCpuSnapshot = result.cpuSnapshot;
      latestMetrics = result.metrics;
      publish(ctx);
    } finally {
      sampling = false;
    }
  };

  const start = (_event: unknown, ctx: ExtensionContext): void => {
    clearTimer(ctx);
    active = true;
    void sample(ctx);
    timer = setInterval(() => {
      if (active) void sample(ctx);
    }, SYSTEM_HEALTH_REFRESH_MS);
    timer.unref?.();
  };

  pi.on("session_start", start);
  pi.on("session_shutdown", (_event, ctx) => clearTimer(ctx));

  pi.registerCommand("system-health", {
    description: "Report or toggle the compact system-health status",
    handler: async (args, ctx) => {
      const command = args.trim().toLowerCase();
      if (command === "toggle" || command === "on" || command === "off") {
        enabled = command === "toggle" ? !enabled : command === "on";
        publish(ctx);
        ctx.ui.notify(
          `${enabled ? "System health indicator on" : "System health indicator off"}. ${formatHealthReport(latestMetrics)}`,
          "info",
        );
        return;
      }
      if (command !== "" && command !== "show") {
        ctx.ui.notify("Usage: /system-health [show|toggle|on|off]", "warning");
        return;
      }
      const hasMetrics =
        latestMetrics.memoryFreePercent !== undefined ||
        latestMetrics.cpuUtilizationPercent !== undefined;
      ctx.ui.notify(formatHealthReport(latestMetrics), hasMetrics ? "info" : "warning");
    },
  });
}
