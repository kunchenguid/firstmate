import { spawn, spawnSync, type ChildProcess } from "node:child_process";
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
  quotaFailureReasonFromReport,
  quotaProviderForPiProvider,
  revalidateFreshQuotaView,
  selectActiveProviderQuota,
  type FreshQuotaView,
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
const DEFAULT_REVISION_CHECK_MS = 1000;
const MAX_TIMER_DELAY_MS = 2_147_483_647;
const WINDOWS_TREE_KILL_TIMEOUT_MS = 5000;
const WINDOWS_JOB_SUPERVISOR = String.raw`
$ErrorActionPreference = "Stop"
$jobSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class FirstmateQuotaJob
{
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint DUPLICATE_SAME_ACCESS = 0x00000002;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const uint STARTF_USESTDHANDLES = 0x00000100;
    const uint WAIT_FAILED = 0xFFFFFFFF;
    const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(
        IntPtr sourceProcess,
        IntPtr sourceHandle,
        IntPtr targetProcess,
        out IntPtr targetHandle,
        uint desiredAccess,
        bool inheritHandle,
        uint options);

    static void Require(bool value)
    {
        if (!value) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    static IntPtr InheritableStdHandle(int id)
    {
        IntPtr current = GetCurrentProcess();
        IntPtr duplicate;
        Require(DuplicateHandle(
            current,
            GetStdHandle(id),
            current,
            out duplicate,
            0,
            true,
            DUPLICATE_SAME_ACCESS));
        return duplicate;
    }

    public static int Run(string executable, string arguments)
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr input = IntPtr.Zero;
        IntPtr output = IntPtr.Zero;
        IntPtr error = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        try
        {
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            IntPtr limitsPointer = Marshal.AllocHGlobal(Marshal.SizeOf(limits));
            try
            {
                Marshal.StructureToPtr(limits, limitsPointer, false);
                Require(SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    limitsPointer,
                    (uint)Marshal.SizeOf(limits)));
            }
            finally
            {
                Marshal.FreeHGlobal(limitsPointer);
            }

            input = InheritableStdHandle(-10);
            output = InheritableStdHandle(-11);
            error = InheritableStdHandle(-12);
            var startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(startup);
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdInput = input;
            startup.hStdOutput = output;
            startup.hStdError = error;
            var commandLine = new StringBuilder("\"" + executable + "\" " + arguments);
            Require(CreateProcessW(
                executable,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                CREATE_SUSPENDED | CREATE_NO_WINDOW,
                IntPtr.Zero,
                null,
                ref startup,
                out process));
            Require(AssignProcessToJobObject(job, process.hProcess));
            if (ResumeThread(process.hThread) == UInt32.MaxValue)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (WaitForSingleObject(process.hProcess, UInt32.MaxValue) == WAIT_FAILED)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint exitCode;
            Require(GetExitCodeProcess(process.hProcess, out exitCode));
            return unchecked((int)exitCode);
        }
        catch
        {
            if (process.hProcess != IntPtr.Zero) TerminateProcess(process.hProcess, 70);
            throw;
        }
        finally
        {
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (input != IntPtr.Zero) CloseHandle(input);
            if (output != IntPtr.Zero) CloseHandle(output);
            if (error != IntPtr.Zero) CloseHandle(error);
            CloseHandle(job);
        }
    }
}
'@
Add-Type -TypeDefinition $jobSource -Language CSharp
$childScript = @'
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$payloadText = [System.Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String($env:FM_QUOTA_JOB_PAYLOAD)
)
$payload = ConvertFrom-Json $payloadText
$command = [string]$payload.command
[string[]]$arguments = @($payload.arguments | ForEach-Object { [string]$_ })
Remove-Item Env:FM_QUOTA_JOB_PAYLOAD -ErrorAction SilentlyContinue
try {
  $resolved = Get-Command -Name $command -CommandType Application,ExternalScript -ErrorAction Stop
} catch {
  exit 127
}
try {
  & $resolved.Source @arguments
  if ($null -eq $LASTEXITCODE) { exit 0 }
  exit [int]$LASTEXITCODE
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 126
}
'@
$childEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
$powershell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $childEncoded"
exit [FirstmateQuotaJob]::Run($powershell, $arguments)
`;

const OFFICIAL_PROVIDER_BASE_URLS: Readonly<Record<string, string>> = {
  anthropic: "https://api.anthropic.com",
  "kimi-coding": "https://api.kimi.com/coding",
  "openai-codex": "https://chatgpt.com/backend-api",
  xai: "https://api.x.ai/v1",
};

const OFFICIAL_PROVIDER_MODEL_APIS: Readonly<Record<string, readonly string[]>> = {
  anthropic: ["anthropic-messages"],
  "github-copilot": ["anthropic-messages", "openai-completions", "openai-responses"],
  "kimi-coding": ["anthropic-messages"],
  "openai-codex": ["openai-codex-responses"],
  xai: ["openai-completions", "openai-responses"],
};

type QuotaProcessResult =
  | { kind: "ok"; stdout: string }
  | { kind: "failed"; stdout: string; exitCode: number | null }
  | { kind: Exclude<QuotaFailureReason, "failed"> };

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
  | {
      kind: "resolving";
      piProvider: string;
      modelRevision: string;
      compositionRevision: string;
    }
  | {
      kind: "supported";
      piProvider: string;
      verification: QuotaVerification;
      credentialRevision: string;
      modelRevision: string;
      compositionRevision: string;
      endpointRevision: string;
    }
  | {
      kind: "unsupported";
      view: Extract<QuotaView, { kind: "unsupported" }>;
      modelRevision: string;
      compositionRevision: string;
    };

type CompatibleProvider = {
  id?: unknown;
  name?: unknown;
  baseUrl?: unknown;
  headers?: unknown;
  auth?: {
    apiKey?: {
      login?: unknown;
      check?: unknown;
      resolve?: unknown;
    };
    oauth?: {
      isSubscription?: boolean;
      login?: unknown;
      refresh?: unknown;
      toAuth?: (credential: StoredOAuthCredential) => Promise<ResolvedOAuthAuth>;
    };
  };
  getModels?: unknown;
  refreshModels?: unknown;
  filterModels?: unknown;
  stream?: unknown;
  streamSimple?: unknown;
  fetchDeferred?: unknown;
  cancelDeferred?: unknown;
};

type CompatibleModelRegistry = {
  getProvider?: (provider: string) => CompatibleProvider | undefined;
  getRegisteredProviderConfig?: (provider: string) => unknown;
  getRegisteredNativeProvider?: (provider: string) => unknown;
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
  modelRevision: string;
  compositionRevision: string;
  endpointRevision: string;
};

type ActiveSession = {
  ctx: ExtensionContext;
  generation: number;
  target: QuotaTarget;
  quota: CachedQuota | null;
  lastFailure: QuotaFailureReason | null;
  process: QuotaProcess | null;
  operationAbort: AbortController | null;
  credentialCheckAbort: AbortController | null;
  credentialWatcher: FSWatcher | null;
  credentialMonitoringAvailable: boolean;
  refreshInFlight: boolean;
  refreshPending: boolean;
  refreshTimer: unknown | null;
  expiryTimer: unknown | null;
  modelRefreshTimer: unknown | null;
  recoveryTimer: unknown | null;
  revisionTimer: unknown | null;
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

function isOfficialProviderModelApi(provider: string, value: unknown): boolean {
  return typeof value === "string" &&
    Boolean(OFFICIAL_PROVIDER_MODEL_APIS[provider]?.includes(value));
}

function activeModelRevision(model: ActiveModel | undefined): string {
  if (!model) return "no-model";
  const endpoint = canonicalBaseUrl(model.baseUrl) ?? model.baseUrl;
  return JSON.stringify([model.provider, model.id, model.api, endpoint]);
}

function effectiveEndpointRevision(provider: string, endpoint: string): string {
  return JSON.stringify([provider, canonicalBaseUrl(endpoint) ?? endpoint]);
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
  if (process.platform === "win32") {
    if (child.exitCode !== null || child.signalCode !== null) return;
    if (child.pid) {
      const result = spawnSync(
        "taskkill",
        ["/PID", String(child.pid), "/T", "/F"],
        {
          stdio: "ignore",
          windowsHide: true,
          timeout: WINDOWS_TREE_KILL_TIMEOUT_MS,
        },
      );
      if (!result.error && result.status === 0) return;
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
  const useWindowsSupervisor = process.platform === "win32";
  const child = useWindowsSupervisor
    ? spawn(
        "powershell.exe",
        [
          "-NoLogo",
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-EncodedCommand",
          Buffer.from(WINDOWS_JOB_SUPERVISOR, "utf16le").toString("base64"),
        ],
        {
          shell: false,
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
          env: {
            ...process.env,
            FM_QUOTA_JOB_PAYLOAD: Buffer.from(JSON.stringify({ command, arguments: args }), "utf8")
              .toString("base64"),
          },
        },
      )
    : spawn(command, args, {
        detached: true,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });
  const processGroupId = !useWindowsSupervisor && child.pid ? child.pid : null;

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

  const receiveStdout = (chunk: Buffer) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > maxOutputBytes) {
      finish({ kind: "overflow" });
      return;
    }
    stdoutChunks.push(chunk);
  };
  const receiveStderr = (chunk: Buffer) => {
    stderrBytes += chunk.length;
    if (stderrBytes > maxOutputBytes) finish({ kind: "overflow" });
  };

  child.stdout?.on("data", receiveStdout);
  child.stderr?.on("data", receiveStderr);
  child.on("error", (error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") {
      finish({ kind: "missing" });
    } else {
      finish({
        kind: "failed",
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        exitCode: null,
      });
    }
  });
  child.on("close", (code) => {
    const stdout = Buffer.concat(stdoutChunks).toString("utf8");
    if (code === 0) {
      finish({ kind: "ok", stdout });
    } else if (useWindowsSupervisor && code === 127) {
      finish({ kind: "missing" });
    } else {
      finish({ kind: "failed", stdout, exitCode: code });
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
  const referenceRevisions = new WeakMap<object, number>();
  let nextReferenceRevision = 1;

  function referenceRevision(value: unknown): number {
    if ((typeof value !== "object" || value === null) && typeof value !== "function") return 0;
    const key = value as object;
    const existing = referenceRevisions.get(key);
    if (existing !== undefined) return existing;
    const revision = nextReferenceRevision++;
    referenceRevisions.set(key, revision);
    return revision;
  }

  function providerCompositionRevision(
    ctx: ExtensionContext,
    model: ActiveModel | undefined,
  ): string {
    if (!model) return "no-provider";
    const registry = ctx.modelRegistry as unknown as CompatibleModelRegistry;
    if (typeof registry.getProvider !== "function") return "provider-inspection-unavailable";
    try {
      const provider = registry.getProvider.call(ctx.modelRegistry, model.provider);
      if (!provider) return "provider-missing";
      const registeredConfig = typeof registry.getRegisteredProviderConfig === "function"
        ? registry.getRegisteredProviderConfig.call(ctx.modelRegistry, model.provider)
        : "unavailable";
      const registeredNative = typeof registry.getRegisteredNativeProvider === "function"
        ? registry.getRegisteredNativeProvider.call(ctx.modelRegistry, model.provider)
        : "unavailable";
      const apiKey = provider.auth?.apiKey;
      const oauth = provider.auth?.oauth;
      const usingOAuth = typeof registry.isUsingOAuth === "function"
        ? registry.isUsingOAuth.call(ctx.modelRegistry, model)
        : "unavailable";
      const authStatus = typeof registry.getProviderAuthStatus === "function"
        ? registry.getProviderAuthStatus.call(ctx.modelRegistry, model.provider)
        : undefined;
      return JSON.stringify([
        referenceRevision(provider),
        referenceRevision(registry.getRegisteredProviderConfig),
        referenceRevision(registeredConfig),
        referenceRevision(registry.getRegisteredNativeProvider),
        referenceRevision(registeredNative),
        provider.id,
        provider.name,
        provider.baseUrl,
        referenceRevision(provider.headers),
        referenceRevision(provider.auth),
        referenceRevision(apiKey),
        referenceRevision(apiKey?.login),
        referenceRevision(apiKey?.check),
        referenceRevision(apiKey?.resolve),
        referenceRevision(oauth),
        oauth?.isSubscription,
        referenceRevision(oauth?.login),
        referenceRevision(oauth?.refresh),
        referenceRevision(oauth?.toAuth),
        referenceRevision(provider.getModels),
        referenceRevision(provider.refreshModels),
        referenceRevision(provider.filterModels),
        referenceRevision(provider.stream),
        referenceRevision(provider.streamSimple),
        referenceRevision(provider.fetchDeferred),
        referenceRevision(provider.cancelDeferred),
        referenceRevision(registry.isUsingOAuth),
        usingOAuth,
        referenceRevision(registry.getProviderAuthStatus),
        authStatus?.configured,
        authStatus?.source,
      ]);
    } catch {
      return "provider-inspection-failed";
    }
  }

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
      const modelRevision = activeModelRevision(model);
      const compositionRevision = providerCompositionRevision(ctx, model);
      if (!model) {
        return {
          kind: "unsupported",
          view: unsupportedView("no model", "no-model"),
          modelRevision,
          compositionRevision,
        };
      }
      if (!quotaProviderForPiProvider(model.provider)) {
        return {
          kind: "unsupported",
          view: unsupportedProvider(model.provider),
          modelRevision,
          compositionRevision,
        };
      }
      if (!isOfficialProviderModelApi(model.provider, model.api)) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "provider-override"),
          modelRevision,
          compositionRevision,
        };
      }
      const registry = ctx.modelRegistry as unknown as CompatibleModelRegistry;
      if (
        typeof registry.getProvider !== "function" ||
        typeof registry.getRegisteredProviderConfig !== "function" ||
        typeof registry.getRegisteredNativeProvider !== "function" ||
        typeof registry.isUsingOAuth !== "function"
      ) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "auth-inspection"),
          modelRevision,
          compositionRevision,
        };
      }
      let provider: CompatibleProvider | undefined;
      try {
        provider = registry.getProvider.call(ctx.modelRegistry, model.provider);
        if (
          registry.getRegisteredProviderConfig.call(ctx.modelRegistry, model.provider) !== undefined ||
          registry.getRegisteredNativeProvider.call(ctx.modelRegistry, model.provider) !== undefined
        ) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "provider-override"),
            modelRevision,
            compositionRevision,
          };
        }
      } catch {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "auth-inspection"),
          modelRevision,
          compositionRevision,
        };
      }
      if (registry.isUsingOAuth.call(ctx.modelRegistry, model)) {
        if (provider?.auth?.oauth?.isSubscription !== true) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "non-subscription-auth"),
            modelRevision,
            compositionRevision,
          };
        }
        return { kind: "resolving", piProvider: model.provider, modelRevision, compositionRevision };
      }
      if (
        model.provider === "kimi-coding" &&
        typeof registry.getProviderAuthStatus === "function" &&
        registry.getProviderAuthStatus.call(ctx.modelRegistry, model.provider).source === "stored"
      ) {
        return { kind: "resolving", piProvider: model.provider, modelRevision, compositionRevision };
      }
      return {
        kind: "unsupported",
        view: unsupportedView(model.provider, "non-subscription-auth"),
        modelRevision,
        compositionRevision,
      };
    }

    async function resolveTarget(
      ctx: ExtensionContext,
      model: ActiveModel | undefined,
      signal: AbortSignal,
    ): Promise<QuotaTarget> {
      const preflight = preflightTarget(ctx, model);
      if (preflight.kind !== "resolving") return preflight;
      if (!model) {
        return {
          kind: "unsupported",
          view: unsupportedView("no model", "no-model"),
          modelRevision: preflight.modelRevision,
          compositionRevision: preflight.compositionRevision,
        };
      }

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
          modelRevision: preflight.modelRevision,
          compositionRevision: preflight.compositionRevision,
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
            modelRevision: preflight.modelRevision,
            compositionRevision: preflight.compositionRevision,
          };
        }
      } else {
        const provider = registry.getProvider?.call(ctx.modelRegistry, model.provider);
        const oauth = provider?.auth?.oauth;
        if (!oauth || typeof oauth.toAuth !== "function") {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "auth-inspection"),
            modelRevision: preflight.modelRevision,
            compositionRevision: preflight.compositionRevision,
          };
        }
        const credential = storedOAuthCredential(rawCredential);
        if (!credential) {
          return {
            kind: "unsupported",
            view: unsupportedView(model.provider, "auth-unavailable"),
            modelRevision: preflight.modelRevision,
            compositionRevision: preflight.compositionRevision,
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
            modelRevision: preflight.modelRevision,
            compositionRevision: preflight.compositionRevision,
          };
        }
        resolvedAuth = authResult.auth;
      }

      const effectiveBaseUrl = resolvedAuth.baseUrl ?? model.baseUrl;
      if (!isOfficialProviderBaseUrl(model.provider, effectiveBaseUrl)) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "custom-endpoint"),
          modelRevision: preflight.modelRevision,
          compositionRevision: preflight.compositionRevision,
        };
      }
      const verification = quotaVerification(model.provider, resolvedAuth.apiKey);
      if (!verification) {
        return {
          kind: "unsupported",
          view: unsupportedView(model.provider, "account-correlation"),
          modelRevision: preflight.modelRevision,
          compositionRevision: preflight.compositionRevision,
        };
      }
      return {
        kind: "supported",
        piProvider: model.provider,
        verification,
        credentialRevision: credentialResult.revision,
        modelRevision: preflight.modelRevision,
        compositionRevision: preflight.compositionRevision,
        endpointRevision: effectiveEndpointRevision(model.provider, effectiveBaseUrl),
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

    function targetMatchesLiveModel(session: ActiveSession): boolean {
      return session.target.modelRevision === activeModelRevision(session.ctx.model) &&
        session.target.compositionRevision === providerCompositionRevision(session.ctx, session.ctx.model);
    }

    function viewForTarget(target: QuotaTarget): QuotaView {
      return target.kind === "unsupported"
        ? target.view
        : { kind: "refreshing", provider: target.piProvider };
    }

    function credentialMonitoringView(session: ActiveSession): QuotaTarget {
      const model = session.ctx.model;
      return {
        kind: "unsupported",
        view: unsupportedView(model?.provider ?? "no model", "credential-monitoring"),
        modelRevision: activeModelRevision(model),
        compositionRevision: providerCompositionRevision(session.ctx, model),
      };
    }

    function resetForLiveModel(session: ActiveSession): void {
      session.generation += 1;
      session.target = session.credentialMonitoringAvailable
        ? preflightTarget(session.ctx, session.ctx.model)
        : credentialMonitoringView(session);
      session.quota = null;
      session.lastFailure = null;
      cancelProcess(session);
      render(session);
    }

    function scheduleLiveModelRefresh(session: ActiveSession): void {
      if (session.modelRefreshTimer !== null || active !== session) return;
      let timer: unknown;
      timer = timers.setTimeout(() => {
        if (active !== session || session.modelRefreshTimer !== timer) return;
        session.modelRefreshTimer = null;
        if (targetMatchesLiveModel(session)) return;
        resetForLiveModel(session);
        void refresh(session);
      }, 0);
      session.modelRefreshTimer = timer;
      unrefTimer(timer);
    }

    function changedLiveModelView(session: ActiveSession): QuotaView | null {
      if (targetMatchesLiveModel(session)) return null;
      scheduleLiveModelRefresh(session);
      const target = session.credentialMonitoringAvailable
        ? preflightTarget(session.ctx, session.ctx.model)
        : credentialMonitoringView(session);
      return viewForTarget(target);
    }

    function recoverableFreshView(view: QuotaView | null): FreshQuotaView | null {
      if (view?.kind === "fresh") return view;
      return view?.kind === "stale" ? view.recoverable ?? null : null;
    }

    function cachedQuotaView(session: ActiveSession, nowMs: number): QuotaView | null {
      if (changedLiveModelView(session) || session.target.kind !== "supported" || !session.quota) {
        return null;
      }
      if (
        session.quota.piProvider !== session.target.piProvider ||
        session.quota.credentialRevision !== session.target.credentialRevision ||
        session.quota.modelRevision !== session.target.modelRevision ||
        session.quota.compositionRevision !== session.target.compositionRevision ||
        session.quota.endpointRevision !== session.target.endpointRevision
      ) return null;
      const cached = session.quota.view;
      const recoverable = recoverableFreshView(cached);
      if (!recoverable) return cached;
      const revalidated = revalidateFreshQuotaView(recoverable, nowMs);
      if (
        revalidated.kind === "fresh" ||
        nowMs >= recoverable.reportFreshUntilMs
      ) {
        session.quota.view = revalidated;
      }
      return revalidated;
    }

    function currentView(session: ActiveSession, nowMs = now()): QuotaView {
      const changedModel = changedLiveModelView(session);
      if (changedModel) return changedModel;
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

    function credentialsChanged(session: ActiveSession): void {
      if (active !== session) return;
      session.generation += 1;
      session.target = preflightTarget(session.ctx, session.ctx.model);
      session.quota = null;
      session.lastFailure = null;
      cancelProcess(session);
      render(session);
      void refresh(session);
    }

    async function checkCredentialRevision(session: ActiveSession): Promise<void> {
      if (
        active !== session ||
        !session.credentialMonitoringAvailable ||
        session.refreshInFlight ||
        session.credentialCheckAbort !== null ||
        session.target.kind !== "supported"
      ) return;
      if (!targetMatchesLiveModel(session)) {
        resetForLiveModel(session);
        void refresh(session);
        return;
      }

      const target = session.target;
      const generation = session.generation;
      const controller = new AbortController();
      session.credentialCheckAbort = controller;
      try {
        const result = await readStoredCredential(target.piProvider, controller.signal);
        if (
          active !== session ||
          session.generation !== generation ||
          session.credentialCheckAbort !== controller ||
          session.target !== target ||
          session.refreshInFlight ||
          !targetMatchesLiveModel(session)
        ) return;
        if (result.kind === "cancelled") return;
        if (result.kind === "ok" && result.revision === target.credentialRevision) return;
        session.credentialCheckAbort = null;
        credentialsChanged(session);
      } finally {
        if (session.credentialCheckAbort === controller) session.credentialCheckAbort = null;
      }
    }

    function watchCredentials(session: ActiveSession): void {
      try {
        const watcher = watchAuthDirectory(dirname(authFile), { persistent: false }, (_event, filename) => {
          if (filename !== null && String(filename) !== basename(authFile)) return;
          credentialsChanged(session);
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

    function scheduleRecoveredView(session: ActiveSession): void {
      if (active !== session || session.recoveryTimer !== null) return;
      let timer: unknown;
      timer = timers.setTimeout(() => {
        if (active !== session || session.recoveryTimer !== timer) return;
        session.recoveryTimer = null;
        render(session);
      }, 0);
      session.recoveryTimer = timer;
      unrefTimer(timer);
    }

    function render(session: ActiveSession, override?: QuotaView): void {
      if (active !== session) return;
      if (session.recoveryTimer !== null) timers.clearTimeout(session.recoveryTimer);
      session.recoveryTimer = null;
      const view = override ?? currentView(session);
      clearExpiry(session);
      const renderScheduledAtMs = now();
      const cachedFreshView = recoverableFreshView(session.quota?.view ?? null);
      const recoverableSkewView = cachedFreshView &&
          renderScheduledAtMs < cachedFreshView.freshnessTimestampMs - 60_000
        ? cachedFreshView
        : null;
      const nextRevalidationMs = view.kind === "fresh"
        ? view.freshUntilMs
        : recoverableSkewView
          ? recoverableSkewView.freshnessTimestampMs - 60_000
          : null;
      if (nextRevalidationMs !== null) {
        let timer: unknown;
        timer = timers.setTimeout(() => {
          if (active !== session || session.expiryTimer !== timer) return;
          session.expiryTimer = null;
          cachedQuotaView(session, now());
          render(session);
        }, Math.min(
          MAX_TIMER_DELAY_MS,
          Math.max(0, nextRevalidationMs - renderScheduledAtMs),
        ));
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
          const changedModel = changedLiveModelView(session);
          const renderView = changedModel ?? (
            view.kind === "fresh" || recoverableSkewView !== null
              ? currentView(session, renderNowMs)
              : view
          );
          if (
            view.kind !== "fresh" &&
            recoverableSkewView !== null &&
            renderView.kind === "fresh"
          ) scheduleRecoveredView(session);
          const plain = formatStatus(renderView, availableWidth, renderNowMs);
          return plain ? [theme.fg("dim", plain)] : [];
        },
        invalidate() {},
      }), { placement: "belowEditor" });
    }

    function cancelCredentialCheck(session: ActiveSession): void {
      session.credentialCheckAbort?.abort();
      session.credentialCheckAbort = null;
    }

    function cancelProcess(session: ActiveSession): void {
      cancelCredentialCheck(session);
      session.operationAbort?.abort();
      session.operationAbort = null;
      if (session.process) session.process.cancel();
      session.process = null;
    }

    function publishRefreshFailure(
      session: ActiveSession,
      failureReason: QuotaFailureReason,
      provider: string,
    ): void {
      const cached = cachedQuotaView(session, now());
      const recoverable = recoverableFreshView(session.quota?.view ?? null);
      session.lastFailure = failureReason;
      if (cached?.kind === "fresh" && session.quota) {
        session.quota.view = { ...cached, refreshFailure: failureReason };
        render(session);
      } else if (recoverable) {
        render(session);
      } else {
        session.quota = null;
        render(session, processFailureView(failureReason, provider));
      }
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

      if (!targetMatchesLiveModel(session)) resetForLiveModel(session);
      session.refreshInFlight = true;
      cancelCredentialCheck(session);
      const generation = session.generation;
      const operationAbort = new AbortController();
      session.operationAbort = operationAbort;
      const startingModel = session.ctx.model;
      const startingModelRevision = activeModelRevision(startingModel);
      const startingCompositionRevision = providerCompositionRevision(session.ctx, startingModel);
      try {
        const target = await resolveTarget(session.ctx, startingModel, operationAbort.signal);
        if (active !== session || session.generation !== generation) return;
        if (
          activeModelRevision(session.ctx.model) !== startingModelRevision ||
          providerCompositionRevision(session.ctx, session.ctx.model) !== startingCompositionRevision
        ) {
          resetForLiveModel(session);
          session.refreshPending = true;
          return;
        }
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
          previousTarget.credentialRevision !== target.credentialRevision ||
          previousTarget.modelRevision !== target.modelRevision ||
          previousTarget.compositionRevision !== target.compositionRevision ||
          previousTarget.endpointRevision !== target.endpointRevision
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
          session.target = {
            kind: "unsupported",
            view: unsupportedProvider(piProvider),
            modelRevision: target.modelRevision,
            compositionRevision: target.compositionRevision,
          };
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
        if (
          activeModelRevision(session.ctx.model) !== startingModelRevision ||
          providerCompositionRevision(session.ctx, session.ctx.model) !== startingCompositionRevision
        ) {
          resetForLiveModel(session);
          session.refreshPending = true;
          return;
        }

        const completedModel = session.ctx.model;
        const completedModelRevision = activeModelRevision(completedModel);
        const completedCompositionRevision = providerCompositionRevision(session.ctx, completedModel);
        const completedTarget = await resolveTarget(session.ctx, completedModel, operationAbort.signal);
        if (
          active !== session ||
          session.generation !== generation ||
          session.process !== running
        ) return;
        if (
          activeModelRevision(session.ctx.model) !== completedModelRevision ||
          providerCompositionRevision(session.ctx, session.ctx.model) !== completedCompositionRevision
        ) {
          resetForLiveModel(session);
          session.refreshPending = true;
          return;
        }
        session.process = null;
        session.target = completedTarget;
        if (completedTarget.kind === "unsupported") {
          session.quota = null;
          session.lastFailure = null;
          render(session);
          return;
        }
        if (
          completedTarget.credentialRevision !== target.credentialRevision ||
          completedTarget.modelRevision !== target.modelRevision ||
          completedTarget.compositionRevision !== target.compositionRevision ||
          completedTarget.endpointRevision !== target.endpointRevision
        ) {
          session.quota = null;
          session.refreshPending = true;
          render(session, { kind: "refreshing", provider: completedTarget.piProvider });
          return;
        }

        const completedProvider = completedTarget.piProvider;
        if (result.kind === "ok") {
          const report = parseQuotaAxiJson(result.stdout, {
            projection: "full",
            expectedProvider: quotaProvider,
          });
          const selected = report
            ? selectTargetReport(report, completedTarget, now())
            : { kind: "malformed", provider: completedProvider } as const;
          const staleFailure = selected.kind === "stale" && report
            ? quotaFailureReasonFromReport(report, completedProvider)
            : null;
          if (staleFailure) {
            publishRefreshFailure(session, staleFailure, completedProvider);
          } else {
            session.lastFailure = null;
            session.quota = {
              view: selected,
              piProvider: completedProvider,
              credentialRevision: completedTarget.credentialRevision,
              modelRevision: completedTarget.modelRevision,
              compositionRevision: completedTarget.compositionRevision,
              endpointRevision: completedTarget.endpointRevision,
            };
            render(session);
          }
        } else if (result.kind !== "cancelled") {
          const failedReport = result.kind === "failed" && result.stdout
            ? parseQuotaAxiJson(result.stdout, {
                projection: "full",
                expectedProvider: quotaProvider,
              })
            : null;
          const failureReason = failedReport
            ? quotaFailureReasonFromReport(failedReport, completedProvider) ?? result.kind
            : result.kind;
          publishRefreshFailure(session, failureReason, completedProvider);
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
      if (session.modelRefreshTimer !== null) timers.clearTimeout(session.modelRefreshTimer);
      session.modelRefreshTimer = null;
      if (session.revisionTimer !== null) timers.clearInterval(session.revisionTimer);
      session.revisionTimer = null;
      if (session.recoveryTimer !== null) timers.clearTimeout(session.recoveryTimer);
      session.recoveryTimer = null;
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

      const session: ActiveSession = {
        ctx,
        generation: 0,
        target: preflightTarget(ctx, ctx.model),
        quota: null,
        lastFailure: null,
        process: null,
        operationAbort: null,
        credentialCheckAbort: null,
        credentialWatcher: null,
        credentialMonitoringAvailable: false,
        refreshInFlight: false,
        refreshPending: false,
        refreshTimer: null,
        expiryTimer: null,
        modelRefreshTimer: null,
        recoveryTimer: null,
        revisionTimer: null,
      };
      active = session;
      watchCredentials(session);
      session.refreshTimer = timers.setInterval(() => {
        void refresh(session);
      }, refreshMs);
      unrefTimer(session.refreshTimer);
      session.revisionTimer = timers.setInterval(() => {
        if (active !== session) return;
        if (!targetMatchesLiveModel(session)) {
          resetForLiveModel(session);
          void refresh(session);
          return;
        }
        if (refreshMs > DEFAULT_REVISION_CHECK_MS) void checkCredentialRevision(session);
      }, Math.min(refreshMs, DEFAULT_REVISION_CHECK_MS));
      unrefTimer(session.revisionTimer);
      render(session);
      void refresh(session);
    }

    pi.on("session_start", (_event, ctx) => {
      start(ctx);
    });
    pi.on("model_select", (_event, ctx) => {
      if (!active) {
        start(ctx);
        return;
      }
      active.ctx = ctx;
      active.generation += 1;
      active.target = active.credentialMonitoringAvailable
        ? preflightTarget(ctx, ctx.model)
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
