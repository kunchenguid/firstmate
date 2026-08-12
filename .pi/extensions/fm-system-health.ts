// Firstmate's compact Pi system-health status.
//
// The extension reports OS free RAM and sampled aggregate CPU utilization only.
// It deliberately does not call a subprocess or inspect files, so the status stays
// cheap and truthful on macOS and on platforms where only Node's portable metrics exist.
import * as os from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const SYSTEM_HEALTH_STATUS_KEY = "firstmate-system-health";
export const SYSTEM_HEALTH_REFRESH_MS = 3_000;

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
};

export type HealthTone = "muted" | "warning" | "error";
export type MetricKind = "memory" | "cpu";
export type HealthTheme = Pick<ExtensionContext["ui"]["theme"], "fg">;

function boundedPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
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
  const memoryFreePercent = calculateMemoryFreePercent(
    sources.totalMemoryBytes,
    sources.freeMemoryBytes,
  );
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

export function sampleCurrentHealth(previousCpuSnapshot?: CpuSnapshot): {
  metrics: HealthMetrics;
  cpuSnapshot: CpuSnapshot | undefined;
} {
  return sampleHealthSources(
    {
      totalMemoryBytes: readOptionalNumber(() => os.totalmem()),
      freeMemoryBytes: readOptionalNumber(() => os.freemem()),
      cpus: readOptionalCpus(),
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

function displayPercent(value: number): string {
  return `${Math.round(boundedPercent(value))}%`;
}

export function formatHealthStatus(metrics: HealthMetrics): string {
  const parts: string[] = [];
  if (metrics.memoryFreePercent !== undefined) {
    parts.push(`RAM ${displayPercent(metrics.memoryFreePercent)} free`);
  }
  if (metrics.cpuUtilizationPercent !== undefined) {
    parts.push(`CPU ${displayPercent(metrics.cpuUtilizationPercent)}`);
  }
  return parts.join(" · ");
}

export function renderHealthStatus(metrics: HealthMetrics, theme: HealthTheme): string {
  const parts: string[] = [];
  if (metrics.memoryFreePercent !== undefined) {
    parts.push(
      theme.fg(
        metricTone("memory", metrics.memoryFreePercent),
        `RAM ${displayPercent(metrics.memoryFreePercent)} free`,
      ),
    );
  }
  if (metrics.cpuUtilizationPercent !== undefined) {
    parts.push(
      theme.fg(
        metricTone("cpu", metrics.cpuUtilizationPercent),
        `CPU ${displayPercent(metrics.cpuUtilizationPercent)}`,
      ),
    );
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

  const clearTimer = (ctx?: ExtensionContext): void => {
    active = false;
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

  const sample = (ctx: ExtensionContext): void => {
    const result = sampleCurrentHealth(previousCpuSnapshot);
    previousCpuSnapshot = result.cpuSnapshot;
    latestMetrics = result.metrics;
    publish(ctx);
  };

  const start = (_event: unknown, ctx: ExtensionContext): void => {
    clearTimer(ctx);
    active = true;
    sample(ctx);
    timer = setInterval(() => {
      if (active) sample(ctx);
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
