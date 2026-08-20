import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, watch, type FSWatcher } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  createQuotaStatusFormatter,
  DEFAULT_QUOTA_FRESHNESS_MS,
  parseQuotaAxiJson,
  quotaProviderForPiProvider,
  revalidateFreshQuotaView,
  selectActiveProviderQuota,
  type ParsedQuotaAxiReport,
  type QuotaFailureReason,
  type QuotaUnsupportedReason,
  type QuotaView,
} from "./lib/fm-pi-quota-status.ts";

const WIDGET_KEY = "firstmate-quota";
const DEFAULT_REFRESH_MS = 5 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 20 * 1000;
const DEFAULT_MAX_OUTPUT_BYTES = 1024 * 1024;
const DEFAULT_MAX_AUTH_BYTES = 1024 * 1024;

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

type AuthDirectoryWatcher = (
  path: string,
  options: { persistent: false },
  listener: (event: "rename" | "change", filename: string | Buffer | null) => void,
) => FSWatcher;

export type FirstmateQuotaStatusOptions = {
  command?: string;
  refreshMs?: number;
  timeoutMs?: number;
  freshnessMs?: number;
  maxOutputBytes?: number;
  maxAuthBytes?: number;
  now?: () => number;
  width?: () => number;
  timers?: QuotaTimerScheduler;
  authFile?: string;
  watchAuthDirectory?: AuthDirectoryWatcher;
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

type StoredApiKeyCredential = {
  type: "api_key";
  key: string;
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
  getProviderAuthStatus?: (provider: string) => {
    configured: boolean;
    source?: "stored" | "runtime" | "environment" | "fallback" | "models_json_key" | "models_json_command";
  };
};

type CachedQuota = {
  view: QuotaView;
  piProvider: string;
  credentialRevision: string;
};

type ActiveSession = {
  ctx: ExtensionContext;
  model: ActiveModel | undefined;
  generation: number;
  target: QuotaTarget;
  quota: CachedQuota | null;
  lastFailure: QuotaFailureReason | null;
  process: QuotaProcess | null;
  operationAbort: AbortController | null;
  credentialWatcher: FSWatcher | null;
  credentialMonitoringAvailable: boolean;
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

function storedApiKeyCredential(value: unknown): StoredApiKeyCredential | null {
  if (!isRecord(value) || value.type !== "api_key" || typeof value.key !== "string") return null;
  if (
    value.key.trim().length === 0 ||
    value.key.startsWith("!") ||
    value.key.includes("$") ||
    /[\u0000-\u001f\u007f]/.test(value.key)
  ) return null;
  return value as StoredApiKeyCredential;
}

function credentialRevision(value: unknown): string {
  try {
    const serialized = value === undefined ? "missing" : JSON.stringify(value);
    if (serialized === undefined) return "malformed";
    return createHash("sha256").update(serialized).digest("hex");
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
  const canonicalAccountId = exactAccountId(auth?.chatgpt_account_id);
  if (!canonicalAccountId) return null;
  for (const candidate of [
    payload["https://api.openai.com/auth/account_id"],
    payload.account_id,
    auth?.account_id,
  ]) {
    const alternativeAccountId = exactAccountId(candidate);
    if (alternativeAccountId && alternativeAccountId !== canonicalAccountId) return null;
  }
  return canonicalAccountId;
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
  const maxAuthBytes = Math.floor(positiveNumber(options.maxAuthBytes, DEFAULT_MAX_AUTH_BYTES));
  const now = options.now ?? Date.now;
  const width = options.width;
  const timers = options.timers ?? defaultTimers;
  const authFile = options.authFile ?? defaultAuthFile();
  const watchAuthDirectory: AuthDirectoryWatcher = options.watchAuthDirectory ?? (
    (path, watchOptions, listener) => watch(path, watchOptions, listener)
  );
  const formatStatus = createQuotaStatusFormatter();

  type BoundedAuthResult =
    | { kind: "ok"; auth: ResolvedOAuthAuth }
    | { kind: "failed" | "timeout" | "cancelled" };

  type BoundedCredentialResult =
    | { kind: "ok"; credential: unknown; revision: string }
    | { kind: "failed" | "timeout" | "cancelled" | "overflow" };

  function readStoredCredential(provider: string, signal: AbortSignal): Promise<BoundedCredentialResult> {
    return new Promise((resolve) => {
      let settled = false;
      let timer: unknown | null = null;
      const finish = (result: BoundedCredentialResult) => {
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

      void (async (): Promise<BoundedCredentialResult> => {
        let handle: Awaited<ReturnType<typeof open>> | null = null;
        try {
          handle = await open(authFile, constants.O_RDONLY | constants.O_NONBLOCK);
          const stats = await handle.stat();
          if (!stats.isFile() || !Number.isSafeInteger(stats.size) || stats.size < 0) {
            return { kind: "failed" };
          }
          if (stats.size > maxAuthBytes) return { kind: "overflow" };
          const buffer = Buffer.alloc(Math.min(maxAuthBytes + 1, stats.size + 1));
          let bytesRead = 0;
          while (bytesRead < buffer.length) {
            const chunk = await handle.read(
              buffer,
              bytesRead,
              buffer.length - bytesRead,
              bytesRead,
            );
            if (chunk.bytesRead === 0) break;
            bytesRead += chunk.bytesRead;
          }
          if (bytesRead > maxAuthBytes) return { kind: "overflow" };
          if (bytesRead !== stats.size) return { kind: "failed" };
          const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
          if (!isRecord(parsed)) return { kind: "failed" };
          const credential = parsed[provider];
          return { kind: "ok", credential, revision: credentialRevision(credential) };
        } catch {
          return { kind: "failed" };
        } finally {
          await handle?.close().catch(() => {});
        }
      })().then(finish, () => finish({ kind: "failed" }));
    });
  }

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

    function unsupportedView(
      piProvider: string,
      reason: QuotaUnsupportedReason,
    ): Extract<QuotaView, { kind: "unsupported" }> {
      return { kind: "unsupported", provider: piProvider, reason };
    }

    function unsupportedProvider(piProvider: string): Extract<QuotaView, { kind: "unsupported" }> {
      const view = selectActiveProviderQuota(
        { generatedAtMs: now(), schemaVersion: 3, projection: "default", providers: [] },
        piProvider,
        { nowMs: now(), freshnessMs },
      );
      return view.kind === "unsupported" ? view : unsupportedView(piProvider, "provider");
    }

    function preflightTarget(ctx: ExtensionContext, model: ActiveModel | undefined): QuotaTarget {
      if (!model) return { kind: "unsupported", view: unsupportedView("no model", "no-model") };
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
          view: unsupportedView(model.provider, "auth-inspection"),
        };
      }
      const provider = registry.getProvider.call(ctx.modelRegistry, model.provider);
      if (registry.isUsingOAuth.call(ctx.modelRegistry, model)) {
        if (provider?.auth?.oauth?.isSubscription !== true) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "non-subscription-auth"),
          };
        }
        return { kind: "resolving", piProvider: model.provider };
      }
      if (
        model.provider === "kimi-coding" &&
        typeof registry.getProviderAuthStatus === "function" &&
        registry.getProviderAuthStatus.call(ctx.modelRegistry, model.provider).source === "stored"
      ) {
        return { kind: "resolving", piProvider: model.provider };
      }
      return {
        kind: "unsupported",
        view: unsupportedView(model.provider, "non-subscription-auth"),
      };
    }

    async function resolveTarget(
      ctx: ExtensionContext,
      model: ActiveModel | undefined,
      signal: AbortSignal,
    ): Promise<QuotaTarget> {
      const preflight = preflightTarget(ctx, model);
      if (preflight.kind !== "resolving") return preflight;
      if (!model) return { kind: "unsupported", view: unsupportedView("no model", "no-model") };

      const registry = ctx.modelRegistry as unknown as CompatibleModelRegistry;
      const credentialResult = await readStoredCredential(model.provider, signal);
      if (credentialResult.kind !== "ok") {
        const reason: QuotaUnsupportedReason = credentialResult.kind === "timeout"
          ? "auth-timeout"
          : credentialResult.kind === "cancelled"
            ? "auth-cancelled"
            : credentialResult.kind === "overflow"
              ? "auth-overflow"
              : "auth-unavailable";
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, reason),
        };
      }
      const rawCredential = credentialResult.credential;
      let resolvedAuth: ResolvedOAuthAuth = {};
      if (!registry.isUsingOAuth?.call(ctx.modelRegistry, model)) {
        const authStatus = registry.getProviderAuthStatus?.call(ctx.modelRegistry, model.provider);
        if (
          model.provider !== "kimi-coding" ||
          authStatus?.source !== "stored" ||
          !storedApiKeyCredential(rawCredential)
        ) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "auth-unavailable"),
          };
        }
      } else {
        const provider = registry.getProvider?.call(ctx.modelRegistry, model.provider);
        const oauth = provider?.auth?.oauth;
        if (!oauth || typeof oauth.toAuth !== "function") {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "auth-inspection"),
          };
        }
        const credential = storedOAuthCredential(rawCredential);
        if (!credential) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "auth-unavailable"),
          };
        }
        const authResult = await resolveOAuthAuth(oauth, credential, signal);
        if (authResult.kind !== "ok") {
          const reason: QuotaUnsupportedReason = authResult.kind === "timeout"
            ? "auth-timeout"
            : authResult.kind === "cancelled"
              ? "auth-cancelled"
              : "auth-unavailable";
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, reason),
          };
        }
        resolvedAuth = authResult.auth;
      }

      const effectiveBaseUrl = resolvedAuth.baseUrl ?? model.baseUrl;
      if (!isOfficialProviderBaseUrl(model.provider, effectiveBaseUrl)) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "custom-endpoint"),
        };
      }
      const verification = quotaVerification(model.provider, resolvedAuth.apiKey);
      if (!verification) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "account-correlation"),
        };
      }
      return {
        kind: "supported",
        piProvider: model.provider,
        verification,
        credentialRevision: credentialResult.revision,
      };
    }

    function selectTargetReport(
      report: ParsedQuotaAxiReport,
      target: Extract<QuotaTarget, { kind: "supported" }>,
      nowMs: number,
    ): QuotaView {
      const verification = target.verification;
      return selectActiveProviderQuota(report, target.piProvider, {
        nowMs,
        freshnessMs,
        expectedAccountId: verification.kind === "account" ? verification.accountId : null,
        expectedSuccessfulSource: verification.kind === "source" ? verification.source : undefined,
      });
    }

    function cachedQuotaView(session: ActiveSession, nowMs: number): QuotaView | null {
      if (session.target.kind !== "supported" || !session.quota) return null;
      if (
        session.quota.piProvider !== session.target.piProvider ||
        session.quota.credentialRevision !== session.target.credentialRevision
      ) return null;
      const cached = session.quota.view;
      if (cached.kind !== "fresh") return cached;
      const revalidated = revalidateFreshQuotaView(cached, nowMs);
      if (
        revalidated.kind === "fresh" ||
        nowMs >= cached.reportFreshUntilMs
      ) {
        session.quota.view = revalidated;
      }
      return revalidated;
    }

    function currentView(session: ActiveSession, nowMs = now()): QuotaView {
      if (session.target.kind === "unsupported") return session.target.view;
      if (session.target.kind === "resolving") {
        return { kind: "refreshing", provider: session.target.piProvider };
      }
      const selected = cachedQuotaView(session, nowMs);
      if (!selected) return { kind: "refreshing", provider: session.target.piProvider };
      if (!session.lastFailure) return selected;
      if (selected.kind === "fresh") {
        return selected.refreshFailure === session.lastFailure
          ? selected
          : { ...selected, refreshFailure: session.lastFailure };
      }
      return selected.kind === "stale"
        ? processFailureView(session.lastFailure, session.target.piProvider)
        : selected;
    }

    function clearExpiry(session: ActiveSession): void {
      if (session.expiryTimer !== null) timers.clearTimeout(session.expiryTimer);
      session.expiryTimer = null;
    }

    function credentialMonitoringView(session: ActiveSession): QuotaTarget {
      const provider = session.model?.provider ?? "no model";
      return {
        kind: "unsupported",
        view: unsupportedView(provider, "credential-monitoring"),
      };
    }

    function failCredentialMonitoring(session: ActiveSession): void {
      session.credentialMonitoringAvailable = false;
      const watcher = session.credentialWatcher;
      session.credentialWatcher = null;
      try {
        watcher?.close();
      } catch {
      }
      if (active !== session) return;
      session.generation += 1;
      session.target = credentialMonitoringView(session);
      session.quota = null;
      session.lastFailure = null;
      cancelProcess(session);
      render(session);
    }

    function watchCredentials(session: ActiveSession): void {
      try {
        const watcher = watchAuthDirectory(dirname(authFile), { persistent: false }, (_event, filename) => {
          if (filename !== null && String(filename) !== basename(authFile)) return;
          if (active !== session) return;
          session.generation += 1;
          session.target = preflightTarget(session.ctx, session.model);
          session.quota = null;
          session.lastFailure = null;
          cancelProcess(session);
          render(session);
          void refresh(session);
        });
        session.credentialWatcher = watcher;
        session.credentialMonitoringAvailable = true;
        watcher.on("error", () => failCredentialMonitoring(session));
        watcher.on("close", () => {
          if (session.credentialWatcher === watcher) failCredentialMonitoring(session);
        });
      } catch {
        failCredentialMonitoring(session);
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
          cachedQuotaView(session, view.freshUntilMs);
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
          const plain = formatStatus(renderView, availableWidth, renderNowMs);
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
      if (!session.credentialMonitoringAvailable) {
        session.target = credentialMonitoringView(session);
        session.quota = null;
        session.lastFailure = null;
        render(session);
        return;
      }
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
        const previousTarget = session.target;
        session.target = target;
        if (target.kind === "unsupported") {
          session.quota = null;
          session.lastFailure = null;
          render(session);
          return;
        }
        if (
          previousTarget.kind !== "supported" ||
          previousTarget.piProvider !== target.piProvider ||
          previousTarget.credentialRevision !== target.credentialRevision
        ) {
          session.quota = null;
          session.lastFailure = null;
        }

        const piProvider = target.piProvider;
        if (currentView(session).kind !== "fresh") {
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
          session.quota = null;
          session.lastFailure = null;
          render(session);
          return;
        }
        if (completedTarget.credentialRevision !== target.credentialRevision) {
          session.quota = null;
          session.refreshPending = true;
          render(session, { kind: "refreshing", provider: completedTarget.piProvider });
          return;
        }

        const completedProvider = completedTarget.piProvider;
        if (result.kind === "ok") {
          session.lastFailure = null;
          const report = parseQuotaAxiJson(result.stdout, { projection: "full" });
          const selected = report
            ? selectTargetReport(report, completedTarget, now())
            : { kind: "malformed", provider: completedProvider } as const;
          session.quota = {
            view: selected,
            piProvider: completedProvider,
            credentialRevision: completedTarget.credentialRevision,
          };
          render(session);
        } else if (result.kind !== "cancelled") {
          const cached = cachedQuotaView(session, now());
          session.lastFailure = result.kind;
          if (cached?.kind === "fresh" && session.quota) {
            session.quota.view = { ...cached, refreshFailure: result.kind };
            render(session);
          } else {
            session.quota = null;
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
      const watcher = session.credentialWatcher;
      session.credentialWatcher = null;
      session.credentialMonitoringAvailable = false;
      watcher?.close();
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
        quota: null,
        lastFailure: null,
        process: null,
        operationAbort: null,
        credentialWatcher: null,
        credentialMonitoringAvailable: false,
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
      active.target = active.credentialMonitoringAvailable
        ? preflightTarget(ctx, event.model)
        : credentialMonitoringView(active);
      active.quota = null;
      active.lastFailure = null;
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
