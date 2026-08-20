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

const STATUS_KEY = "zz-firstmate-quota";
const DEFAULT_REFRESH_MS = 5 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 20 * 1000;
const DEFAULT_MAX_OUTPUT_BYTES = 1024 * 1024;
const DEFAULT_WIDTH = 160;

type QuotaProcessResult =
  | { kind: "ok"; stdout: string }
  | { kind: "missing" | "failed" | "timeout" | "overflow" | "cancelled" };

type QuotaProcess = {
  promise: Promise<QuotaProcessResult>;
  cancel: () => void;
  child: ChildProcess;
};

export type FirstmateQuotaStatusOptions = {
  command?: string;
  refreshMs?: number;
  timeoutMs?: number;
  freshnessMs?: number;
  maxOutputBytes?: number;
  now?: () => number;
  width?: () => number;
};

type ActiveSession = {
  generation: number;
  ctx: ExtensionContext;
  piProvider: string;
  report: ParsedQuotaAxiReport | null;
  process: QuotaProcess | null;
  refreshPending: boolean;
  refreshTimer: ReturnType<typeof setInterval> | null;
  resizeHandler: (() => void) | null;
};

function positiveNumber(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

function terminalWidth(): number {
  const stdoutWidth = process.stdout.columns;
  if (typeof stdoutWidth === "number" && Number.isFinite(stdoutWidth) && stdoutWidth > 0) return stdoutWidth;
  const environmentWidth = Number(process.env.COLUMNS);
  if (Number.isFinite(environmentWidth) && environmentWidth > 0) return environmentWidth;
  return DEFAULT_WIDTH;
}

function killProcess(child: ChildProcess): void {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (process.platform !== "win32" && child.pid) {
      process.kill(-child.pid, "SIGKILL");
      return;
    }
  } catch {
  }
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
    if (kill) killProcess(child);
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
  const width = options.width ?? terminalWidth;

  return function firstmateQuotaStatus(pi: ExtensionAPI): void {
    let nextGeneration = 0;
    let active: ActiveSession | null = null;

    function currentView(session: ActiveSession): QuotaView {
      if (!session.piProvider) return { kind: "unsupported", provider: "no model" };
      if (!session.report) return { kind: "unavailable", provider: session.piProvider, label: null };
      return selectActiveProviderQuota(session.report, session.piProvider, {
        nowMs: now(),
        freshnessMs,
      });
    }

    function render(session: ActiveSession, override?: QuotaView | string): void {
      if (active !== session) return;
      const availableWidth = Math.max(1, Math.floor(width()));
      const plain = typeof override === "string"
        ? override
        : formatQuotaStatus(override ?? currentView(session), availableWidth, now());
      const text = plain ? session.ctx.ui.theme.fg("dim", plain) : undefined;
      session.ctx.ui.setStatus(STATUS_KEY, text);
    }

    async function refresh(session: ActiveSession): Promise<void> {
      if (active !== session) return;
      const selected = selectActiveProviderQuota(
        session.report ?? { generatedAtMs: now(), schemaVersion: 3, providers: [] },
        session.piProvider,
        { nowMs: now(), freshnessMs },
      );
      if (selected.kind === "unsupported") {
        render(session, selected);
        return;
      }
      if (session.process) {
        session.refreshPending = true;
        return;
      }
      if (!session.report || currentView(session).kind !== "fresh") {
        render(session, "Quota: refreshing");
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
      if (session.refreshTimer) clearInterval(session.refreshTimer);
      session.refreshTimer = null;
      if (session.resizeHandler) process.stdout.off("resize", session.resizeHandler);
      session.resizeHandler = null;
      if (session.process) session.process.cancel();
      session.process = null;
      session.refreshPending = false;
      session.ctx.ui.setStatus(STATUS_KEY, undefined);
      if (active === session) active = null;
    }

    function start(ctx: ExtensionContext): void {
      if (active) stop(active);
      if (ctx.mode !== "tui") return;

      const session: ActiveSession = {
        generation: ++nextGeneration,
        ctx,
        piProvider: ctx.model?.provider ?? "",
        report: null,
        process: null,
        refreshPending: false,
        refreshTimer: null,
        resizeHandler: null,
      };
      active = session;
      session.resizeHandler = () => render(session);
      process.stdout.on("resize", session.resizeHandler);
      session.refreshTimer = setInterval(() => {
        void refresh(session);
      }, refreshMs);
      session.refreshTimer.unref();
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
