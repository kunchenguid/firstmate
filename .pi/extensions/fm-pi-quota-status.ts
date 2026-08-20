import { spawn, type ChildProcess } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_QUOTA_FRESHNESS_MS,
  formatQuotaStatus,
  parseQuotaAxiJson,
  selectActiveProviderQuota,
  type ParsedQuotaAxiReport,
  type QuotaView,
} from "./lib/fm-pi-quota-status.ts";

const WIDGET_KEY = "firstmate-quota";
const DEFAULT_REFRESH_MS = 5 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 20 * 1000;
const DEFAULT_MAX_OUTPUT_BYTES = 1024 * 1024;

type QuotaProcessResult =
  | { kind: "ok"; stdout: string }
  | { kind: "missing" | "failed" | "timeout" | "overflow" | "cancelled" };

type QuotaProcess = {
  promise: Promise<QuotaProcessResult>;
  cancel: () => void;
  child: ChildProcess;
};

export type QuotaTimerScheduler = {
  setTimeout: (callback: () => void, delayMs: number) => unknown;
  clearTimeout: (timer: unknown) => void;
  setInterval: (callback: () => void, delayMs: number) => unknown;
  clearInterval: (timer: unknown) => void;
};

export type FirstmateQuotaStatusOptions = {
  command?: string;
  refreshMs?: number;
  timeoutMs?: number;
  freshnessMs?: number;
  maxOutputBytes?: number;
  now?: () => number;
  width?: () => number;
  timers?: QuotaTimerScheduler;
};

type ActiveSession = {
  ctx: ExtensionContext;
  piProvider: string;
  report: ParsedQuotaAxiReport | null;
  process: QuotaProcess | null;
  refreshPending: boolean;
  refreshTimer: unknown | null;
  expiryTimer: unknown | null;
};

function positiveNumber(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

const defaultTimers: QuotaTimerScheduler = {
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
  setInterval: (callback, delayMs) => setInterval(callback, delayMs),
  clearInterval: (timer) => clearInterval(timer as ReturnType<typeof setInterval>),
};

function unrefTimer(timer: unknown): void {
  if (typeof timer !== "object" || timer === null || !("unref" in timer)) return;
  const unref = (timer as { unref?: unknown }).unref;
  if (typeof unref === "function") unref.call(timer);
}

function killProcess(child: ChildProcess, processGroupId: number | null): void {
  if (processGroupId !== null) {
    try {
      process.kill(-processGroupId, "SIGKILL");
      return;
    } catch {
    }
  }
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    child.kill("SIGKILL");
  } catch {
  }
}

export function runQuotaAxiJson(options: {
  command?: string;
  timeoutMs?: number;
  maxOutputBytes?: number;
} = {}): QuotaProcess {
  const command = options.command ?? "quota-axi";
  const timeoutMs = positiveNumber(options.timeoutMs, DEFAULT_TIMEOUT_MS);
  const maxOutputBytes = positiveNumber(options.maxOutputBytes, DEFAULT_MAX_OUTPUT_BYTES);
  const child = spawn(command, ["--json"], {
    detached: process.platform !== "win32",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const processGroupId = process.platform !== "win32" && child.pid ? child.pid : null;

  let settled = false;
  let stdoutBytes = 0;
  let stderrBytes = 0;
  const stdoutChunks: Buffer[] = [];
  let resolveResult: (result: QuotaProcessResult) => void = () => {};

  const promise = new Promise<QuotaProcessResult>((resolve) => {
    resolveResult = resolve;
  });
  const timeout = setTimeout(() => {
    finish({ kind: "timeout" }, true);
  }, timeoutMs);
  timeout.unref();

  function finish(result: QuotaProcessResult, kill = false): void {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    if (kill) killProcess(child, processGroupId);
    resolveResult(result);
  }

  child.stdout?.on("data", (chunk: Buffer) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > maxOutputBytes) {
      finish({ kind: "overflow" }, true);
      return;
    }
    stdoutChunks.push(chunk);
  });
  child.stderr?.on("data", (chunk: Buffer) => {
    stderrBytes += chunk.length;
    if (stderrBytes > maxOutputBytes) finish({ kind: "overflow" }, true);
  });
  child.on("error", (error: NodeJS.ErrnoException) => {
    finish({ kind: error.code === "ENOENT" ? "missing" : "failed" });
  });
  child.on("close", (code) => {
    if (code === 0) {
      finish({ kind: "ok", stdout: Buffer.concat(stdoutChunks).toString("utf8") });
    } else {
      finish({ kind: "failed" });
    }
  });

  return {
    child,
    promise,
    cancel: () => finish({ kind: "cancelled" }, true),
  };
}

function processFailureView(kind: Exclude<QuotaProcessResult["kind"], "ok">, provider: string): QuotaView {
  if (kind === "cancelled") return { kind: "unavailable", provider, label: null };
  return { kind: "unavailable", provider, label: null };
}

export function createFirstmateQuotaStatusExtension(options: FirstmateQuotaStatusOptions = {}) {
  const command = options.command ?? "quota-axi";
  const refreshMs = positiveNumber(options.refreshMs, DEFAULT_REFRESH_MS);
  const timeoutMs = positiveNumber(options.timeoutMs, DEFAULT_TIMEOUT_MS);
  const freshnessMs = positiveNumber(options.freshnessMs, DEFAULT_QUOTA_FRESHNESS_MS);
  const maxOutputBytes = positiveNumber(options.maxOutputBytes, DEFAULT_MAX_OUTPUT_BYTES);
  const now = options.now ?? Date.now;
  const width = options.width;
  const timers = options.timers ?? defaultTimers;

  return function firstmateQuotaStatus(pi: ExtensionAPI): void {
    let active: ActiveSession | null = null;

    function currentView(session: ActiveSession): QuotaView {
      if (!session.piProvider) return { kind: "unsupported", provider: "no model" };
      if (!session.report) return { kind: "unavailable", provider: session.piProvider, label: null };
      return selectActiveProviderQuota(session.report, session.piProvider, {
        nowMs: now(),
        freshnessMs,
      });
    }

    function clearExpiry(session: ActiveSession): void {
      if (session.expiryTimer !== null) timers.clearTimeout(session.expiryTimer);
      session.expiryTimer = null;
    }

    function render(session: ActiveSession, override?: QuotaView): void {
      if (active !== session) return;
      const view = override ?? currentView(session);
      clearExpiry(session);
      if (view.kind === "fresh") {
        let timer: unknown;
        timer = timers.setTimeout(() => {
          if (active !== session || session.expiryTimer !== timer) return;
          session.expiryTimer = null;
          render(session);
        }, Math.max(0, view.freshUntilMs - now()));
        session.expiryTimer = timer;
        unrefTimer(timer);
      }
      session.ctx.ui.setWidget(WIDGET_KEY, (_tui, theme) => ({
        render(componentWidth: number): string[] {
          const boundedComponentWidth = Math.max(0, Math.floor(componentWidth));
          const configuredWidth = width?.();
          const availableWidth = typeof configuredWidth === "number" && Number.isFinite(configuredWidth) && configuredWidth > 0
            ? Math.min(boundedComponentWidth, Math.floor(configuredWidth))
            : boundedComponentWidth;
          const plain = formatQuotaStatus(view, availableWidth, now());
          return plain ? [theme.fg("dim", plain)] : [];
        },
        invalidate() {},
      }), { placement: "belowEditor" });
    }

    function cancelProcess(session: ActiveSession): void {
      if (session.process) session.process.cancel();
      session.process = null;
      session.refreshPending = false;
    }

    async function refresh(session: ActiveSession): Promise<void> {
      if (active !== session) return;
      const selected = selectActiveProviderQuota(
        session.report ?? { generatedAtMs: now(), schemaVersion: 3, providers: [] },
        session.piProvider,
        { nowMs: now(), freshnessMs },
      );
      if (selected.kind === "unsupported") {
        cancelProcess(session);
        render(session, selected);
        return;
      }
      if (session.process) {
        session.refreshPending = true;
        return;
      }
      if (!session.report || currentView(session).kind !== "fresh") {
        render(session, { kind: "refreshing", provider: session.piProvider });
      }

      const running = runQuotaAxiJson({ command, timeoutMs, maxOutputBytes });
      session.process = running;
      const result = await running.promise;
      if (active !== session || session.process !== running) return;
      session.process = null;

      if (result.kind === "ok") {
        const report = parseQuotaAxiJson(result.stdout);
        if (report) {
          session.report = report;
          render(session);
        } else {
          session.report = null;
          render(session, { kind: "malformed", provider: session.piProvider });
        }
      } else if (result.kind !== "cancelled") {
        const stillFresh = session.report ? currentView(session) : null;
        if (stillFresh?.kind === "fresh") {
          render(session, stillFresh);
        } else {
          session.report = null;
          render(session, processFailureView(result.kind, session.piProvider));
        }
      }

      if (session.refreshPending && active === session) {
        session.refreshPending = false;
        void refresh(session);
      }
    }

    function stop(session: ActiveSession): void {
      if (session.refreshTimer !== null) timers.clearInterval(session.refreshTimer);
      session.refreshTimer = null;
      clearExpiry(session);
      cancelProcess(session);
      session.ctx.ui.setWidget(WIDGET_KEY, undefined);
      if (active === session) active = null;
    }

    function start(ctx: ExtensionContext): void {
      if (active) stop(active);
      if (ctx.mode !== "tui") return;

      const session: ActiveSession = {
        ctx,
        piProvider: ctx.model?.provider ?? "",
        report: null,
        process: null,
        refreshPending: false,
        refreshTimer: null,
        expiryTimer: null,
      };
      active = session;
      session.refreshTimer = timers.setInterval(() => {
        void refresh(session);
      }, refreshMs);
      unrefTimer(session.refreshTimer);
      void refresh(session);
    }

    pi.on("session_start", (_event, ctx) => {
      start(ctx);
    });
    pi.on("model_select", (event, ctx) => {
      if (!active) {
        start(ctx);
        return;
      }
      active.piProvider = event.model.provider;
      render(active);
      void refresh(active);
    });
    pi.on("session_shutdown", () => {
      if (active) stop(active);
    });
  };
}

export default createFirstmateQuotaStatusExtension();
