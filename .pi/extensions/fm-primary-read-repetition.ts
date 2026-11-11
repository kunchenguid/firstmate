// Managed Pi primary read-loop containment. No startup command, fleet mutation,
// model routing, tool replay or authority over worker/monitor sessions.
import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DEFAULT_LIMITS, HISTORY_TYPE, NOTICE_TYPE, ReadRepetition, readLimits, type ReadLimits } from "./lib/fm-primary-read-repetition-policy.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const physical = (path: string): string => realpathSync(path);

type PrimaryOptions = {
  root: string; state: string; home: string; agentDir: string; pid: number;
  env: NodeJS.ProcessEnv; read?: (path: string) => string;
  parentPid?: (pid: number) => number;
  platform?: NodeJS.Platform;
};

export function primarySessionContext(ctx: ExtensionContext, options: PrimaryOptions): boolean {
  try {
    if ((options.platform ?? process.platform) !== "linux" ||
        options.env.FM_TASK_ID || options.env.FM_TASK_INBOX || options.env.FM_SUPERVISION_ACTOR ||
        physical(options.home) !== physical(options.root) || physical(ctx.cwd) !== physical(options.root) ||
        physical(ctx.sessionManager.getCwd()) !== physical(options.root)) return false;
    const encoded = `--${resolve(options.root).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
    // The branch deliberately uses state/branch-session instead. A custom SDK
    // session does not gain root ownership just by sharing the process/lock.
    if (resolve(ctx.sessionManager.getSessionDir()) !== resolve(options.agentDir, "sessions", encoded)) return false;
    return true;
  } catch { return false; }
}

export function primaryOwnsContext(ctx: ExtensionContext, options: PrimaryOptions): boolean {
  if (!primarySessionContext(ctx, options)) return false;
  const read = options.read ?? ((path: string) => readFileSync(path, "utf8"));
  try {
    const markerPid = read(join(options.state, ".pi-turnend-extension-loaded")).split(/\r?\n/)[1];
    if (markerPid !== String(options.pid)) return false;
    const lockPid = read(join(options.state, ".lock")).trim();
    if (!/^[0-9]+$/.test(lockPid) || Number(lockPid) <= 1) return false;
    let pid = options.pid;
    for (let i = 0; i < 8 && pid > 1; i++) {
      if (String(pid) === lockPid) return true;
      // Linux is the currently verified platform, including wrapper ancestry.
      pid = (options.parentPid ?? ((child) => {
        if (process.platform === "win32") return 0;
        const result = spawnSync("ps", ["-o", "ppid=", "-p", String(child)], {
          encoding: "utf8", timeout: 1000,
        });
        return result.status === 0 && /^\d+$/.test(result.stdout.trim()) ? Number(result.stdout.trim()) : 0;
      }))(pid);
      if (!Number.isSafeInteger(pid)) return false;
    }
  } catch { /* Missing ownership evidence leaves this extension inert. */ }
  return false;
}

function operational(text: string): boolean {
  // Reserve the full marked protocol namespace, including persisted legacy
  // untyped inputs and future kinds. None represents fresh interactive intent.
  return text.startsWith("\u2063FIRSTMATE_OP: ") ||
    text.startsWith("[fm-from-firstmate]\u2063") || text.startsWith("\u2063Supervisor escalate (");
}

export function registerReadRepetitionGuard(pi: ExtensionAPI, options: {
  root: string; owns: (ctx: ExtensionContext) => boolean;
  acceptsInput?: (ctx: ExtensionContext) => boolean; now?: () => number;
  limits?: Readonly<ReadLimits>;
}): void {
  const limits = options.limits ?? DEFAULT_LIMITS;
  if (!limits.enabled) return;
  let sessionId: string | undefined;
  let guard = new ReadRepetition(options.root, options.now, limits);
  let announced = false;
  let pendingResetSessionId: string | undefined;

  const activate = (ctx: ExtensionContext): boolean => {
    if (!options.owns(ctx)) return false;
    const id = ctx.sessionManager.getSessionId();
    if (id !== sessionId) {
      guard = new ReadRepetition(options.root, options.now, limits);
      // getBranch includes pre-compaction custom entries. Never rebuild from
      // compacted LLM context or reset merely because agent_start fires.
      const entries = ctx.sessionManager.getBranch();
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.type === "custom" && entry.customType === HISTORY_TYPE) {
          guard.restore(entry.data); break;
        }
      }
      sessionId = id;
      announced = Boolean(guard.stopped);
      // A durable activation receipt distinguishes a loaded extension from an
      // enabled guard that actually proved ownership. Never write it for a
      // worker, a probe, or another owner's session.
      pi.appendEntry("fm-read-repetition-activation-v1", { ...limits, stopped: announced });
    }
    if (pendingResetSessionId === id) {
      pendingResetSessionId = undefined;
      guard.reset(); announced = false; persist();
    }
    return true;
  };
  const persist = (): void => pi.appendEntry(HISTORY_TYPE, guard.snapshot());
  const stop = (ctx: ExtensionContext, reason: string): void => {
    // Stop synchronously before returning the veto. No awaiting abort(): that
    // would deadlock the current tool_call handler against its own agent run.
    ctx.abort();
    if (announced) return;
    announced = true;
    persist();
    pi.sendMessage({ customType: NOTICE_TYPE, content: reason, display: true }, { triggerTurn: false });
  };

  pi.on("session_start", (_event, ctx) => { activate(ctx); });
  pi.on("input", (event, ctx) => {
    if ((event.source !== "interactive" && event.source !== "rpc") || operational(event.text) ||
        (!event.text.trim() && !event.images?.length) || !(options.acceptsInput ?? options.owns)(ctx)) return;
    // Startup can reclaim the lock after input. Persist the reset only once
    // this same eligible root session proves ownership.
    pendingResetSessionId = ctx.sessionManager.getSessionId();
    activate(ctx);
  });
  pi.on("agent_start", (_event, ctx) => {
    if (activate(ctx) && guard.stopped) stop(ctx, guard.stopped);
  });
  // Pi may compact at turn_end after aborting a tool batch. That inference has
  // a separate controller, so the stopped owner must veto it at its own hook.
  pi.on("session_before_compact", (_event, ctx) => {
    if (activate(ctx) && guard.stopped) return { cancel: true };
  });
  pi.on("tool_call", (event, ctx) => {
    if (!activate(ctx)) return;
    const reason = guard.before(event.toolCallId, event.toolName, event.input);
    if (!reason) return;
    if (guard.stopped) stop(ctx, reason);
    return { block: true, reason };
  });
  pi.on("tool_result", (event, ctx) => {
    if (!activate(ctx)) { guard.discardPending(event.toolCallId); return; }
    if (guard.complete(event)) persist();
  });
}

export function loadReadRepetitionLimits(home: string, config: string, platform = process.platform): Readonly<ReadLimits> {
  let limits: Readonly<ReadLimits>;
  try {
    limits = readLimits(JSON.parse(readFileSync(config, "utf8")));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw new Error(`Cannot load read-repetition.json: ${String(error)}`);
    }
    limits = DEFAULT_LIMITS;
  }
  if (!limits.enabled) return limits;
  if (platform !== "linux") throw new Error("Read repetition guard currently supports Linux Pi only; disable enabled in read-repetition.json on this platform.");
  // The managed entrypoint and helper deliberately use different names from
  // the ignored workaround, so even a pre-feature updater preserves its bytes.
  const legacy = join(home, ".pi/extensions/fm-read-repetition-guard.ts");
  try {
    lstatSync(legacy);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return limits;
    throw new Error(`Cannot inspect legacy read guard: ${String(error)}`);
  }
  throw new Error("Legacy fm-read-repetition-guard.ts detected; preserve its source/configuration and move its entrypoint outside .pi/extensions before enabling the managed guard. See docs/configuration.md#pi-repeated-read-containment.");
}

export default function (pi: ExtensionAPI): void {
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const config = join(process.env.FM_CONFIG_OVERRIDE || join(home, "config"), "read-repetition.json");
  const limits = loadReadRepetitionLimits(root, config);
  const primaryOptions = (): PrimaryOptions => ({
    root, home, state: process.env.FM_STATE_OVERRIDE || join(home, "state"),
    agentDir: process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"),
    pid: process.pid, env: process.env,
  });
  registerReadRepetitionGuard(pi, {
    root, limits,
    acceptsInput: (ctx) => primarySessionContext(ctx, primaryOptions()),
    owns: (ctx) => primaryOwnsContext(ctx, primaryOptions()),
  });
}
