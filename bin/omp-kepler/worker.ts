// Programmatic, one-prompt worker. Importing this module does not import OMP.
import { readFileSync, statSync, fstatSync, mkdirSync, realpathSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isAbsolute, join, relative } from "node:path";
import type { CreateAgentSessionOptions, CreateAgentSessionResult } from "@oh-my-pi/pi-coding-agent/sdk";
import type { Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import type { SettingsOptions } from "@oh-my-pi/pi-coding-agent/config/settings";
import type { ExtensionUIContext } from "@oh-my-pi/pi-coding-agent/extensibility/extensions/types";
import { ApprovalBroker, type Capsule, canonical, credentialGuard, digest, validateGate, verifyCredit } from "./contract";
import { approvalOnlyUI, createConfinedTools } from "./tools";

export const PINNED = {
  "retry.enabled": false, "retry.modelFallback": false, "retry.usageAwareFallback": false,
  "retry.fallbackChains": {}, "retry.usageReservePolicy": "fail-closed", "tools.approvalMode": "always-ask",
  "compaction.enabled": false, "compaction.midTurnEnabled": false, "compaction.idleEnabled": false, "compaction.asyncEnabled": false,
  "contextPromotion.enabled": false, "advisor.enabled": false, "images.urls.enabled": false,
  "providers.openaiWebsockets": "off", "secrets.enabled": false, "codexResets.autoRedeem": "no",
  "lsp.enabled": false, "bash.enabled": false, "eval.py": false, "eval.js": false, "github.enabled": false,
  "web_search.enabled": false, "plan.defaultOnStartup": false, "title.refreshOnReplan": false,
  "autolearn.enabled": false, "memory.backend": "off", extensions: [], "prewalk.enabled": false,
  "goal.enabled": false, "goal.continuationModes": [], externalThinking: false, "async.enabled": false,
  "startup.checkUpdate": false, "marketplace.autoUpdate": "off", includeWorkspaceTree: false,
  "features.unexpectedStopDetection": "none",
} satisfies NonNullable<SettingsOptions["overrides"]>;

function canonicalExistingPath(value: string, error: string): string {
  if (typeof value !== "string" || !isAbsolute(value) || realpathSync(value) !== value) throw Error(error);
  return value;
}
function overlaps(left: string, right: string): boolean {
  const distance = relative(left, right);
  return distance === "" || (!distance.startsWith("..") && !isAbsolute(distance));
}
export function assertSettings(settings: Settings): void {
  for (const [key, value] of Object.entries(PINNED)) {
    if (canonical(settings.get(key as Parameters<Settings["get"]>[0])) !== canonical(value)) throw Error("effective_policy_changed");
  }
}
export function options(c: Capsule, dependencies: Pick<CreateAgentSessionOptions, "settings" | "authStorage" | "modelRegistry" | "sessionManager" | "customTools" | "getApiKey">,
                        bootstrap: string, agentDir: string): CreateAgentSessionOptions {
  validateGate(c);
  return {
    ...dependencies, cwd: bootstrap, additionalDirectories: [], agentDir, spawns: "", model: c.model,
    rebindModelAfterDiscovery: false, scopedModels: [{model: c.model}], deadline: c.deadline * 1000,
    toolNames: [...c.tools], restrictToolNames: true, allowRestrictedCustomTools: true, requireYieldTool: false,
    enableMCP: false, enableLsp: false, enableIrc: false, skipPythonPreflight: true, autoApprove: false,
    hasUI: false, interactivePrompts: true, disableExtensionDiscovery: true,
    extensions: [], additionalExtensionPaths: [], preloadedExtensionPaths: [], preloadedPreparedExtensions: [], preloadedCustomToolPaths: [],
    skills: [], rules: [], contextFiles: [], promptTemplates: [], slashCommands: [], taskDepth: 0,
    systemPrompt: `You are the assigned ${c.role} for ${c.task}. Execute only the approved brief using the supplied confined tools. The assigned repository is ${c.worktree}.`,
  };
}

type Factory = (input: CreateAgentSessionOptions) => Promise<CreateAgentSessionResult>;
export function assertOptions(c: Capsule, input: CreateAgentSessionOptions): void {
  const expected = options(c, {}, input.cwd ?? "", input.agentDir ?? "");
  for (const [key, value] of Object.entries(expected)) {
    if (canonical(input[key as keyof CreateAgentSessionOptions]) !== canonical(value)) throw Error("session_options_weakened");
  }
  const allowed = new Set([...Object.keys(expected), "settings", "authStorage", "modelRegistry", "sessionManager", "customTools", "getApiKey"]);
  if (Object.keys(input).some(key => !allowed.has(key))) throw Error("unexpected_session_options");
  if (!input.settings || !input.authStorage || !input.modelRegistry || !input.sessionManager || typeof input.getApiKey !== "function" ||
      canonical(input.customTools?.map(t => t.name)) !== canonical(c.tools)) throw Error("explicit_runtime_dependencies_required");
}
export async function runApproved(c: Capsule, input: CreateAgentSessionOptions, factory: Factory,
                                  initialize: (result: CreateAgentSessionResult) => Promise<void>, emit: (event: unknown) => void): Promise<void> {
  validateGate(c);
  assertOptions(c, input);
  const result = await factory(input);
  let cancelled = false;
  let terminal = false;
  const session = result.session;
  let unsubscribe = () => {};
  const cancel = (): void => {
    cancelled = true;
    void session.abort().catch(() => {});
  };
  process.once("SIGTERM", cancel);
  const timer = setTimeout(cancel, Math.max(0, c.deadline * 1000 - Date.now()));
  try {
    if (!session.model || ["provider", "id", "api", "baseUrl"].some(key => session.model?.[key as keyof Capsule["model"]] !== c.model[key as keyof Capsule["model"]])) throw Error("resolved_model_changed");
    if (canonical([...session.getActiveToolNames()].sort()) !== canonical([...c.tools].sort()) ||
        canonical([...session.getEnabledToolNames()].sort()) !== canonical([...c.tools].sort()) || result.mcpManager || result.lspServers?.length || result.modelFallbackMessage) throw Error("resolved_runtime_changed");
    if (!input.settings) throw Error("settings_missing");
    assertSettings(input.settings);
    unsubscribe = session.subscribe(event => {
      if (event.type === "agent_start") {
        if (cancelled || Date.now() / 1000 >= c.deadline) { cancel(); return; }
        terminal = false;
        emit({type: "agent_start"});
      } else if (event.type === "agent_end") {
        if ("willContinue" in event || (event.isTerminal !== undefined && typeof event.isTerminal !== "boolean")) {
          cancel(); emit({type: "worker_failure"}); return;
        }
        terminal = event.isTerminal !== false;
        emit({type: "agent_end", isTerminal: event.isTerminal !== false});
      }
    });
    await initialize(result);
    if (!session.extensionRunner?.hasUI()) throw Error("native_approval_ui_required");
    if (cancelled || Date.now() / 1000 >= c.deadline) throw Error("worker_expired");
    await session.prompt(c.brief, {expandPromptTemplates: false});
    if (cancelled || !terminal) throw Error("terminal_receipt_required");
    if (session.getLastAssistantMessage()?.stopReason !== "stop") throw Error("successful_assistant_stop_required");
    const text = session.getLastAssistantText() ?? "";
    emit({type: "worker_result", task: c.task, stopReason: "stop", text: text.slice(0, 8192), truncated: text.length > 8192});
  } finally {
    clearTimeout(timer);
    process.removeListener("SIGTERM", cancel);
    unsubscribe();
    // The independent controller kills/reaps a stuck cleanup after its grace.
    const cleanup = await Promise.race([session.dispose().then(() => "ok", () => "failed"),
      new Promise<string>(resolve => setTimeout(() => resolve("timeout"), 250))]);
    if (cleanup !== "ok") throw Error(`worker_cleanup_${cleanup}`);
  }
}

interface Payload {capsule: Capsule; capsuleHash: string; state: string; credentialFd: number; ownerPublicKey: string}
async function main(): Promise<void> {
  const text = await Bun.stdin.text();
  if (text.length > 131072) throw Error("authenticated_capsule_required");
  const payload: Payload = JSON.parse(text);
  const c = payload.capsule;
  validateGate(c);
  if (digest(c) !== payload.capsuleHash) throw Error("capsule_bytes_changed");
  const check = spawnSync("/usr/bin/python3", ["-I", join(import.meta.dir, "controller.py"), "authority", c.task],
    {encoding: "utf8", timeout: 15000, env: {PATH: "/usr/bin:/bin", LANG: "C.UTF-8"}});
  if (check.status !== 0 || check.stdout.trim() !== payload.capsuleHash) throw Error("trusted_host_authority_required");
  const host = JSON.parse(readFileSync("/etc/firstmate/omp-kepler/host.json", "utf8"));
  if (payload.ownerPublicKey !== readFileSync(host.ownerPublicKey, "utf8") || payload.state !== join(host.stateRoot, c.task)) throw Error("custody_binding_changed");
  if (process.platform !== "linux") throw Error("operational_linux_boundary_required");
  const ownFields = readFileSync(`/proc/${process.pid}/stat`, "utf8").split(")").slice(1).join(")").trim().split(/\s+/);
  const bootId = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  const ownIdentity = `linux:${bootId}:${ownFields[19]}:${ownFields[2]}:${ownFields[1]}`;
  const receipt = JSON.parse(readFileSync(join(payload.state, "receipt.json"), "utf8"));
  if (receipt.pid !== process.pid || receipt.watchdogPid !== process.ppid || receipt.start !== ownIdentity || receipt.capsuleHash !== payload.capsuleHash || receipt.task !== c.task || receipt.reaped !== false) throw Error("owned_watchdog_binding_required");
  if (process.env.HOME !== join(payload.state, "bootstrap") || process.cwd() !== process.env.HOME || Object.keys(process.env).some(key => !["PATH", "HOME", "XDG_CONFIG_HOME", "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "BUN_RUNTIME_TRANSPILER_CACHE_PATH", "PI_NO_TITLE", "OMP_SKIP_SETUP", "LANG"].includes(key))) throw Error("neutral_bootstrap_required");
  const credentialStat = statSync(c.credentialFile), fdStat = fstatSync(payload.credentialFd);
  if (credentialStat.dev !== fdStat.dev || credentialStat.ino !== fdStat.ino || fdStat.mode & 0o077) throw Error("credential_descriptor_changed");
  const credential = readFileSync(payload.credentialFd, "utf8").trim();
  if (!credential || credential.length > 16384) throw Error("custodied_credential_missing");
  const checkCredit = (): void => verifyCredit(JSON.parse(readFileSync(join(payload.state, "credit.json"), "utf8")), c, payload.capsuleHash, payload.ownerPublicKey);
  checkCredit();
  const runtimeModules = canonicalExistingPath(c.runtime.nodeModules, "canonical_runtime_path_required");
  const runtimeBun = canonicalExistingPath(c.runtime.bun, "canonical_runtime_path_required");
  const worktree = canonicalExistingPath(c.worktree, "canonical_worktree_required");
  const source = canonicalExistingPath(import.meta.dir, "canonical_source_path_required");
  if ([runtimeModules, runtimeBun, source].some(path => overlaps(worktree, path))) throw Error("trusted_paths_inside_worker_scope");
  const root = join(runtimeModules, "@oh-my-pi/pi-coding-agent/src");
  // These are the first operational SDK imports, after all authority gates.
  const sdk: typeof import("@oh-my-pi/pi-coding-agent/sdk") = await import(join(root, "sdk.ts"));
  const settingsModule: typeof import("@oh-my-pi/pi-coding-agent/config/settings") = await import(join(root, "config/settings.ts"));
  const authModule: typeof import("@oh-my-pi/pi-coding-agent/session/auth-storage") = await import(join(root, "session/auth-storage.ts"));
  const modelModule: typeof import("@oh-my-pi/pi-coding-agent/config/model-registry") = await import(join(root, "config/model-registry.ts"));
  const sessionModule: typeof import("@oh-my-pi/pi-coding-agent/session/session-manager") = await import(join(root, "session/session-manager.ts"));
  const runtimeModule: typeof import("@oh-my-pi/pi-coding-agent/modes/runtime-init") = await import(join(root, "modes/runtime-init.ts"));
  const themeModule: typeof import("@oh-my-pi/pi-coding-agent/modes/theme/theme") = await import(join(root, "modes/theme/theme.ts"));
  const bootstrap = process.cwd(), agentDir = join(bootstrap, "agent");
  mkdirSync(agentDir, {recursive: true, mode: 0o700});
  const queue = join(payload.state, "approvals");
  mkdirSync(queue, {mode: 0o700});
  const settings = await settingsModule.Settings.init({inMemory: true, cwd: bootstrap, agentDir, overrides: PINNED});
  assertSettings(settings);
  const denyFetch = Object.assign(async () => { throw Error("discovery_network_refused"); },
    {preconnect: () => { throw Error("discovery_preconnect_refused"); }});
  const authStorage = await authModule.AuthStorage.create(join(agentDir, "auth.db"), {
    configValueResolver: async () => undefined, usageProviderResolver: () => undefined, usageFetch: denyFetch,
    refreshOAuthCredential: async () => { throw Error("oauth_refresh_not_authorized"); },
  });
  authStorage.setRuntimeApiKey(c.model.provider, credential);
  const modelRegistry = new modelModule.ModelRegistry(authStorage, join(agentDir, "models.yml"), {
    ignoreLocalModelConfig: true, settings, cacheDbPath: join(agentDir, "models.db"), fetch: denyFetch,
  });
  const sessionManager = sessionModule.SessionManager.inMemory(bootstrap);
  await sessionManager.setSessionName(c.task, "user");
  const broker = new ApprovalBroker(c, payload.capsuleHash, payload.ownerPublicKey);
  let cancelled = false;
  const abort = (): void => { cancelled = true; };
  process.once("SIGTERM", abort);
  const input = options(c, {settings, authStorage, modelRegistry, sessionManager,
    customTools: createConfinedTools(broker, "/usr/bin/python3", join(import.meta.dir, "fs_boundary.py")),
    getApiKey: requested => {checkCredit(); return credentialGuard(c, credential, () => cancelled)(requested);}}, bootstrap, agentDir);
  const ui: ExtensionUIContext = approvalOnlyUI(broker, queue, themeModule.theme);
  try {
    await runApproved(c, input, sdk.createAgentSession, async result => {
      await runtimeModule.initializeExtensions(result.session, {mode: "print", uiContext: ui,
        reportSendError: () => { throw Error("extension_send_refused"); }, reportRuntimeError: () => { cancelled = true; },
        onShutdown: () => { cancelled = true; }});
      result.setToolUIContext(ui, true);
    }, event => process.stdout.write(canonical(event) + "\n"));
  } finally {
    process.removeListener("SIGTERM", abort);
    authStorage.close();
  }
}
if (import.meta.main) {
  main().catch(() => { process.stdout.write('{"type":"worker_failure"}\n'); process.exitCode = 1; });
}
