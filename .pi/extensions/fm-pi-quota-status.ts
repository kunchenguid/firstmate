import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync, watch, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_QUOTA_FRESHNESS_MS,
  formatQuotaStatus,
  parseQuotaAxiJson,
  quotaProviderForPiProvider,
  selectActiveProviderQuota,
  type ParsedQuotaAxiReport,
  type QuotaFailureReason,
  type QuotaView,
} from "./lib/fm-pi-quota-status.ts";

const WIDGET_KEY = "firstmate-quota";
const DEFAULT_REFRESH_MS = 5 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 20 * 1000;
const DEFAULT_MAX_OUTPUT_BYTES = 1024 * 1024;

const OFFICIAL_PROVIDER_BASE_URLS: Readonly<Record<string, string>> = {
  anthropic: "https://api.anthropic.com",
  "kimi-coding": "https://api.kimi.com/coding",
  "openai-codex": "https://chatgpt.com/backend-api",
  xai: "https://api.x.ai/v1",
};

type QuotaProcessResult =
  | { kind: "ok"; stdout: string }
  | { kind: QuotaFailureReason };

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
  authFile?: string;
};

type ActiveModel = NonNullable<ExtensionContext["model"]>;

type QuotaVerification =
  | { kind: "account"; accountId: string | null }
  | { kind: "source"; source: string };

type StoredOAuthCredential = {
  type: "oauth";
  access: string;
  refresh: string;
  expires: number;
  [key: string]: unknown;
};

type ResolvedOAuthAuth = {
  apiKey?: string;
  baseUrl?: string;
};

type QuotaTarget =
  | { kind: "resolving"; piProvider: string }
  | {
      kind: "supported";
      piProvider: string;
      verification: QuotaVerification;
      credentialRevision: string;
    }
  | { kind: "unsupported"; view: Extract<QuotaView, { kind: "unsupported" }> };

type CompatibleModelRegistry = {
  getProvider?: (provider: string) => {
    auth?: {
      oauth?: {
        isSubscription?: boolean;
        toAuth?: (credential: StoredOAuthCredential) => Promise<ResolvedOAuthAuth>;
      };
    };
  } | undefined;
  isUsingOAuth?: (model: ActiveModel) => boolean;
};

type ActiveSession = {
  ctx: ExtensionContext;
  model: ActiveModel | undefined;
  generation: number;
  target: QuotaTarget;
  report: ParsedQuotaAxiReport | null;
  process: QuotaProcess | null;
  operationAbort: AbortController | null;
  credentialRevision: string;
  credentialWatcher: FSWatcher | null;
  refreshInFlight: boolean;
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function defaultAuthFile(): string {
  const configured = process.env.PI_CODING_AGENT_DIR;
  let agentDir = configured && configured.trim() ? configured : join(homedir(), ".pi", "agent");
  if (agentDir === "~") agentDir = homedir();
  else if (agentDir.startsWith("~/")) agentDir = join(homedir(), agentDir.slice(2));
  return join(agentDir, "auth.json");
}

function storedCredential(authFile: string, provider: string): unknown {
  try {
    const parsed: unknown = JSON.parse(readFileSync(authFile, "utf8"));
    return isRecord(parsed) ? parsed[provider] : undefined;
  } catch {
    return undefined;
  }
}

function storedOAuthCredential(value: unknown): StoredOAuthCredential | null {
  if (!isRecord(value)) return null;
  if (
    value.type !== "oauth" ||
    typeof value.access !== "string" ||
    value.access.length === 0 ||
    typeof value.refresh !== "string" ||
    value.refresh.length === 0 ||
    typeof value.expires !== "number" ||
    !Number.isFinite(value.expires)
  ) return null;
  return value as StoredOAuthCredential;
}

function credentialRevision(value: unknown): string {
  try {
    return value === undefined ? "missing" : JSON.stringify(value);
  } catch {
    return "malformed";
  }
}

function canonicalBaseUrl(value: string): string | null {
  try {
    const parsed = new URL(value);
    if (parsed.username || parsed.password || parsed.search || parsed.hash) return null;
    const pathname = parsed.pathname.replace(/\/+$/, "");
    return `${parsed.protocol}//${parsed.host}${pathname}`;
  } catch {
    return null;
  }
}

function isOfficialProviderBaseUrl(provider: string, value: string): boolean {
  const canonical = canonicalBaseUrl(value);
  if (!canonical) return false;
  if (provider === "github-copilot") {
    return /^https:\/\/api\.(?:individual|business|enterprise)\.githubcopilot\.com$/.test(canonical);
  }
  const expected = OFFICIAL_PROVIDER_BASE_URLS[provider];
  return Boolean(expected && canonical === canonicalBaseUrl(expected));
}

function exactAccountId(value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > 200) return null;
  if (value.trim() !== value || /[\u0000-\u001f\u007f-\u009f]/.test(value)) return null;
  return value;
}

function jwtPayload(token: string | undefined): Record<string, unknown> | null {
  if (!token) return null;
  const encoded = token.split(".")[1];
  if (!encoded) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

function activeAccountId(provider: string, apiKey: string | undefined): string | null {
  if (provider !== "openai-codex") return null;
  const payload = jwtPayload(apiKey);
  if (!payload) return null;
  const auth = typeof payload["https://api.openai.com/auth"] === "object" &&
      payload["https://api.openai.com/auth"] !== null &&
      !Array.isArray(payload["https://api.openai.com/auth"])
    ? payload["https://api.openai.com/auth"] as Record<string, unknown>
    : null;
  for (const candidate of [
    payload["https://api.openai.com/auth/account_id"],
    payload.account_id,
    auth?.chatgpt_account_id,
    auth?.account_id,
  ]) {
    const accountId = exactAccountId(candidate);
    if (accountId) return accountId;
  }
  return null;
}

function quotaVerification(provider: string, apiKey: string | undefined): QuotaVerification | null {
  if (provider === "openai-codex") {
    return { kind: "account", accountId: activeAccountId(provider, apiKey) };
  }
  if (provider === "kimi-coding") return { kind: "source", source: "pi:kimi-coding" };
  return null;
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
  full?: boolean;
  provider?: string;
} = {}): QuotaProcess {
  const command = options.command ?? "quota-axi";
  const timeoutMs = positiveNumber(options.timeoutMs, DEFAULT_TIMEOUT_MS);
  const maxOutputBytes = positiveNumber(options.maxOutputBytes, DEFAULT_MAX_OUTPUT_BYTES);
  const args = [
    "--json",
    ...(options.full ? ["--full"] : []),
    ...(options.provider ? ["--provider", options.provider] : []),
  ];
  const child = spawn(command, args, {
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
    finish({ kind: "timeout" });
  }, timeoutMs);
  timeout.unref();

  function finish(result: QuotaProcessResult): void {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    killProcess(child, processGroupId);
    resolveResult(result);
  }

  child.stdout?.on("data", (chunk: Buffer) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > maxOutputBytes) {
      finish({ kind: "overflow" });
      return;
    }
    stdoutChunks.push(chunk);
  });
  child.stderr?.on("data", (chunk: Buffer) => {
    stderrBytes += chunk.length;
    if (stderrBytes > maxOutputBytes) finish({ kind: "overflow" });
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
    cancel: () => finish({ kind: "cancelled" }),
  };
}

function processFailureView(reason: QuotaFailureReason, provider: string): QuotaView {
  return { kind: "failure", provider, reason };
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
  const authFile = options.authFile ?? defaultAuthFile();

  type BoundedAuthResult =
    | { kind: "ok"; auth: ResolvedOAuthAuth }
    | { kind: "failed" | "timeout" | "cancelled" };

  function resolveOAuthAuth(
    oauth: { toAuth?: (credential: StoredOAuthCredential) => Promise<ResolvedOAuthAuth> },
    credential: StoredOAuthCredential,
    signal: AbortSignal,
  ): Promise<BoundedAuthResult> {
    return new Promise((resolve) => {
      let settled = false;
      let timer: unknown | null = null;
      const finish = (result: BoundedAuthResult) => {
        if (settled) return;
        settled = true;
        if (timer !== null) timers.clearTimeout(timer);
        signal.removeEventListener("abort", onAbort);
        resolve(result);
      };
      const onAbort = () => finish({ kind: "cancelled" });
      if (signal.aborted) {
        finish({ kind: "cancelled" });
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
      timer = timers.setTimeout(() => finish({ kind: "timeout" }), timeoutMs);
      unrefTimer(timer);
      Promise.resolve()
        .then(() => oauth.toAuth?.(credential))
        .then((auth) => {
          if (
            !isRecord(auth) ||
            (auth.apiKey !== undefined && typeof auth.apiKey !== "string") ||
            (auth.baseUrl !== undefined && typeof auth.baseUrl !== "string")
          ) {
            finish({ kind: "failed" });
            return;
          }
          finish({ kind: "ok", auth });
        }, () => finish({ kind: "failed" }));
    });
  }

  return function firstmateQuotaStatus(pi: ExtensionAPI): void {
    let active: ActiveSession | null = null;

    function unsupportedProvider(piProvider: string): Extract<QuotaView, { kind: "unsupported" }> {
      const view = selectActiveProviderQuota(
        { generatedAtMs: now(), schemaVersion: 3, projection: "default", providers: [] },
        piProvider,
        { nowMs: now(), freshnessMs },
      );
      return view.kind === "unsupported"
        ? view
        : { kind: "unsupported", provider: piProvider };
    }

    function preflightTarget(ctx: ExtensionContext, model: ActiveModel | undefined): QuotaTarget {
      if (!model) return { kind: "unsupported", view: { kind: "unsupported", provider: "no model" } };
      if (!quotaProviderForPiProvider(model.provider)) {
        return { kind: "unsupported", view: unsupportedProvider(model.provider) };
      }
      const registry = ctx.modelRegistry as unknown as CompatibleModelRegistry;
      if (
        typeof registry.getProvider !== "function" ||
        typeof registry.isUsingOAuth !== "function"
      ) {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (auth inspection unavailable)` },
        };
      }
      const provider = registry.getProvider.call(ctx.modelRegistry, model.provider);
      if (provider?.auth?.oauth?.isSubscription !== true || !registry.isUsingOAuth.call(ctx.modelRegistry, model)) {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (non-subscription auth)` },
        };
      }
      return { kind: "resolving", piProvider: model.provider };
    }

    async function resolveTarget(
      ctx: ExtensionContext,
      model: ActiveModel | undefined,
      signal: AbortSignal,
    ): Promise<QuotaTarget> {
      const preflight = preflightTarget(ctx, model);
      if (preflight.kind !== "resolving") return preflight;
      if (!model) return { kind: "unsupported", view: { kind: "unsupported", provider: "no model" } };

      const registry = ctx.modelRegistry as unknown as CompatibleModelRegistry;
      const provider = registry.getProvider?.call(ctx.modelRegistry, model.provider);
      const oauth = provider?.auth?.oauth;
      if (!oauth || typeof oauth.toAuth !== "function") {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (auth inspection unavailable)` },
        };
      }

      const rawCredential = storedCredential(authFile, model.provider);
      const credential = storedOAuthCredential(rawCredential);
      if (!credential) {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (auth unavailable)` },
        };
      }
      if (credential.expires <= now()) {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (auth expired)` },
        };
      }

      const authResult = await resolveOAuthAuth(oauth, credential, signal);
      if (authResult.kind !== "ok") {
        const reason = authResult.kind === "timeout"
          ? "auth timed out"
          : authResult.kind === "cancelled"
            ? "auth cancelled"
            : "auth unavailable";
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (${reason})` },
        };
      }

      const effectiveBaseUrl = authResult.auth.baseUrl ?? model.baseUrl;
      if (!isOfficialProviderBaseUrl(model.provider, effectiveBaseUrl)) {
        return {
          kind: "unsupported",
          view: { kind: "unsupported", provider: `${model.provider} (custom endpoint)` },
        };
      }
      const verification = quotaVerification(model.provider, authResult.auth.apiKey);
      if (!verification) {
        return {
          kind: "unsupported",
          view: {
            kind: "unsupported",
            provider: `${model.provider} (account correlation unavailable)`,
          },
        };
      }
      return {
        kind: "supported",
        piProvider: model.provider,
        verification,
        credentialRevision: credentialRevision(rawCredential),
      };
    }

    function currentView(session: ActiveSession, nowMs = now()): QuotaView {
      if (session.target.kind === "unsupported") return session.target.view;
      if (session.target.kind === "resolving") {
        return { kind: "refreshing", provider: session.target.piProvider };
      }
      if (activeCredentialRevision(session.model) !== session.target.credentialRevision) {
        return { kind: "refreshing", provider: session.target.piProvider };
      }
      if (!session.report) return { kind: "refreshing", provider: session.target.piProvider };
      const verification = session.target.verification;
      return selectActiveProviderQuota(session.report, session.target.piProvider, {
        nowMs,
        freshnessMs,
        expectedAccountId: verification.kind === "account" ? verification.accountId : undefined,
        expectedSuccessfulSource: verification.kind === "source" ? verification.source : undefined,
      });
    }

    function clearExpiry(session: ActiveSession): void {
      if (session.expiryTimer !== null) timers.clearTimeout(session.expiryTimer);
      session.expiryTimer = null;
    }

    function activeCredentialRevision(model: ActiveModel | undefined): string {
      return model
        ? credentialRevision(storedCredential(authFile, model.provider))
        : "no-model";
    }

    function watchCredentials(session: ActiveSession): void {
      try {
        session.credentialWatcher = watch(dirname(authFile), { persistent: false }, (_event, filename) => {
          if (filename !== null && String(filename) !== basename(authFile)) return;
          if (active !== session) return;
          const revision = activeCredentialRevision(session.model);
          if (revision === session.credentialRevision) return;
          session.credentialRevision = revision;
          session.generation += 1;
          session.target = preflightTarget(session.ctx, session.model);
          session.report = null;
          cancelProcess(session);
          render(session);
          void refresh(session);
        });
        session.credentialWatcher.on("error", () => {});
      } catch {
        session.credentialWatcher = null;
      }
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
          const renderNowMs = now();
          const renderView = view.kind === "fresh" ? currentView(session, renderNowMs) : view;
          const plain = formatQuotaStatus(renderView, availableWidth, renderNowMs);
          return plain ? [theme.fg("dim", plain)] : [];
        },
        invalidate() {},
      }), { placement: "belowEditor" });
    }

    function cancelProcess(session: ActiveSession): void {
      session.operationAbort?.abort();
      session.operationAbort = null;
      if (session.process) session.process.cancel();
      session.process = null;
    }

    async function refresh(session: ActiveSession): Promise<void> {
      if (active !== session) return;
      if (session.refreshInFlight) {
        session.refreshPending = true;
        return;
      }

      session.refreshInFlight = true;
      const generation = session.generation;
      const operationAbort = new AbortController();
      session.operationAbort = operationAbort;
      try {
        const target = await resolveTarget(session.ctx, session.model, operationAbort.signal);
        if (active !== session || session.generation !== generation) return;
        session.target = target;
        if (target.kind === "unsupported") {
          render(session);
          return;
        }
        session.credentialRevision = target.credentialRevision;

        const piProvider = target.piProvider;
        if (!session.report || currentView(session).kind !== "fresh") {
          render(session, { kind: "refreshing", provider: piProvider });
        }

        const quotaProvider = quotaProviderForPiProvider(piProvider);
        if (!quotaProvider) {
          session.target = { kind: "unsupported", view: unsupportedProvider(piProvider) };
          render(session);
          return;
        }
        const running = runQuotaAxiJson({
          command,
          timeoutMs,
          maxOutputBytes,
          full: true,
          provider: quotaProvider,
        });
        session.process = running;
        const result = await running.promise;
        if (
          active !== session ||
          session.generation !== generation ||
          session.process !== running
        ) return;

        const completedTarget = await resolveTarget(session.ctx, session.model, operationAbort.signal);
        if (
          active !== session ||
          session.generation !== generation ||
          session.process !== running
        ) return;
        session.process = null;
        session.target = completedTarget;
        if (completedTarget.kind === "unsupported") {
          render(session);
          return;
        }
        session.credentialRevision = completedTarget.credentialRevision;
        if (completedTarget.credentialRevision !== target.credentialRevision) {
          session.report = null;
          session.refreshPending = true;
          render(session, { kind: "refreshing", provider: completedTarget.piProvider });
          return;
        }

        const completedProvider = completedTarget.piProvider;
        if (result.kind === "ok") {
          const report = parseQuotaAxiJson(result.stdout, { projection: "full" });
          if (report) {
            session.report = report;
            render(session);
          } else {
            session.report = null;
            render(session, { kind: "malformed", provider: completedProvider });
          }
        } else if (result.kind !== "cancelled") {
          const stillFresh = session.report ? currentView(session) : null;
          if (stillFresh?.kind === "fresh") {
            render(session, stillFresh);
          } else {
            session.report = null;
            render(session, processFailureView(result.kind, completedProvider));
          }
        }
      } finally {
        if (session.operationAbort === operationAbort) session.operationAbort = null;
        session.refreshInFlight = false;
        if (session.refreshPending && active === session) {
          session.refreshPending = false;
          void refresh(session);
        }
      }
    }

    function stop(session: ActiveSession): void {
      if (session.refreshTimer !== null) timers.clearInterval(session.refreshTimer);
      session.refreshTimer = null;
      clearExpiry(session);
      session.refreshPending = false;
      session.credentialWatcher?.close();
      session.credentialWatcher = null;
      cancelProcess(session);
      session.ctx.ui.setWidget(WIDGET_KEY, undefined);
      if (active === session) active = null;
    }

    function start(ctx: ExtensionContext): void {
      if (active) stop(active);
      if (ctx.mode !== "tui") return;

      const model = ctx.model;
      const session: ActiveSession = {
        ctx,
        model,
        generation: 0,
        target: preflightTarget(ctx, model),
        report: null,
        process: null,
        operationAbort: null,
        credentialRevision: activeCredentialRevision(model),
        credentialWatcher: null,
        refreshInFlight: false,
        refreshPending: false,
        refreshTimer: null,
        expiryTimer: null,
      };
      active = session;
      watchCredentials(session);
      session.refreshTimer = timers.setInterval(() => {
        void refresh(session);
      }, refreshMs);
      unrefTimer(session.refreshTimer);
      render(session);
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
      active.ctx = ctx;
      active.model = event.model;
      active.generation += 1;
      active.target = preflightTarget(ctx, event.model);
      active.credentialRevision = activeCredentialRevision(event.model);
      cancelProcess(active);
      render(active);
      void refresh(active);
    });
    pi.on("session_shutdown", () => {
      if (active) stop(active);
    });
  };
}

export default createFirstmateQuotaStatusExtension();
