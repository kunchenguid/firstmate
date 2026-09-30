// Opt-in restricted supervision for a Pi primary that runs without a general
// shell tool. docs/pi-restricted-supervision.md owns the launch command and the
// operator contract; this header owns the mechanism.
//
// Selection is explicit twice over. Pi never discovers this file on its own,
// because it sits in a subdirectory with no index.ts, so it loads only from an
// explicit -e path; and even then it registers nothing - no tool, command, or
// event handler - unless FM_PI_RESTRICTED_SUPERVISION is exactly "1". Every
// other Pi session and every other harness is unaffected.
//
// Once selected, the restriction is checked rather than assumed: before taking
// the lock, draining, or advancing delivery, the session's active tools must be
// exactly this file's tools plus the watcher's fm_watch_arm_pi. Any other tool,
// such as Pi's built-in bash, means the model is not restricted and this file
// refuses to act, so its deterministic delivery pass can never run beside a
// supervisor that could also be driving the same work by hand.
//
// What it does in a restricted session:
//   - session_start acquires this home's session lock by running bin/fm-lock.sh
//     with no arguments as a direct child of this Pi process, which is what
//     anchors the lock to Pi rather than to a short-lived child. It runs no
//     other startup work, and there is no model-callable lock tool. Handlers
//     run in load order and are awaited, so loading this file before the
//     watcher extension lets the watcher arm in its own session_start.
//   - fm_drain runs bin/fm-wake-drain.sh to present queued wakes, and with
//     acknowledge: true runs exactly the acknowledgement that its own previous
//     presentation printed. The model supplies no sequence, generation, path,
//     or command; a presentation too large to show whole stores no
//     acknowledgement, so no wake is ever consumed unseen.
//   - fm_deliver, plus a pass on a fixed interval from session start and after
//     every agent run, runs bin/fm-deliver-cycle.sh, which owns what a pass
//     does. Passes are serialized: a trigger that arrives while one runs is
//     skipped rather than queued.
// Both tools act only while this Pi process holds the session lock.
//
// Every script path comes from this file's own firstmate root, never from model
// input. Children run without a shell, with fixed arguments, a bounded run
// time that kills their whole process group, bounded captured output, and a
// forwarded environment limited to the names below, so a model-provider key in
// Pi's own environment is never handed to them.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { firstmateShellInvocation } from "../lib/fm-operational-input.ts";

const ENABLE_ENV = "FM_PI_RESTRICTED_SUPERVISION";
const RESTRICTED_TOOLS = new Set(["fm_drain", "fm_deliver", "fm_watch_arm_pi"]);
const FORWARDED_ENV_NAMES = new Set([
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "TMPDIR", "TZ",
  "SSH_AUTH_SOCK", "GITHUB_TOKEN",
  // Git for Windows needs these to start bash at all.
  "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "USERPROFILE", "APPDATA",
  "LOCALAPPDATA", "TEMP", "TMP", "MSYSTEM",
]);
const FORWARDED_ENV_PREFIXES = [
  "FM_", "LC_", "XDG_", "GIT_", "GH_", "GLAB_", "GITLAB_", "TASKS_AXI_",
  "TREEHOUSE_", "TMUX", "HERDR_", "ZELLIJ", "ORCA_", "CMUX_",
];
const LOCK_TIMEOUT_MS = 30_000;
const DRAIN_TIMEOUT_MS = 60_000;
const DELIVER_TIMEOUT_MS = 600_000;
const KILL_GRACE_MS = 2_000;
const CAPTURE_LIMIT_BYTES = 1024 * 1024;
const MODEL_OUTPUT_LIMIT = 64 * 1024;
const ACK_LINE =
  /^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain\.sh --ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)$/gm;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const drainScript = `${fmRoot}/bin/fm-wake-drain.sh`;
const deliverScript = `${fmRoot}/bin/fm-deliver-cycle.sh`;

type Notify = (message: string, type?: "info" | "warning" | "error") => void;
type Ui = { notify?: Notify } | undefined;
type RunResult = {
  status: number | null;
  output: string;
  overflow: boolean;
  timedOut: boolean;
  aborted: boolean;
  error: string;
};
type PendingAck = { through: string; generation: string };

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function forwardedEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    const key = process.platform === "win32" ? name.toUpperCase() : name;
    if (FORWARDED_ENV_NAMES.has(key) || FORWARDED_ENV_PREFIXES.some((prefix) => key.startsWith(prefix))) {
      env[name] = value;
    }
  }
  env.FM_HOME = fmHome;
  env.FM_ROOT_OVERRIDE = fmRoot;
  env.FM_STATE_OVERRIDE = state;
  return env;
}

function runEngine(
  script: string,
  args: readonly string[],
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<RunResult> {
  return new Promise((resolveResult) => {
    const result: RunResult = { status: null, output: "", overflow: false, timedOut: false, aborted: false, error: "" };
    let captured = 0;
    let settled = false;
    let closed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let child: ChildProcess;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolveResult(result);
    };
    const invocation = firstmateShellInvocation(script, args);
    const group = process.platform !== "win32";
    try {
      child = spawn(invocation.command, invocation.args, {
        cwd: fmHome,
        env: forwardedEnv(),
        shell: false,
        detached: group,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      result.error = error instanceof Error ? error.message : String(error);
      finish();
      return;
    }
    // The whole group, so a grandchild such as a forge CLI cannot outlive the
    // bound; never after close, when the group id may already be reused.
    const kill = (sig: NodeJS.Signals): void => {
      if (closed) return;
      try {
        if (group && child.pid) process.kill(-child.pid, sig);
        else child.kill(sig);
      } catch {
      }
    };
    const stop = (): void => {
      kill("SIGTERM");
      setTimeout(() => {
        kill("SIGKILL");
        finish();
      }, KILL_GRACE_MS);
    };
    const capture = (chunk: Buffer): void => {
      if (result.overflow) return;
      if (captured + chunk.length > CAPTURE_LIMIT_BYTES) {
        result.overflow = true;
        return;
      }
      captured += chunk.length;
      result.output += chunk.toString("utf8");
    };
    child.stdout?.on("data", capture);
    child.stderr?.on("data", capture);
    child.on("error", (error: Error) => {
      result.error = error.message;
      finish();
    });
    child.on("close", (code) => {
      closed = true;
      result.status = code;
      finish();
    });
    timer = setTimeout(() => {
      result.timedOut = true;
      stop();
    }, timeoutMs);
    if (signal) {
      if (signal.aborted) {
        result.aborted = true;
        stop();
      } else {
        signal.addEventListener("abort", () => {
          result.aborted = true;
          stop();
        }, { once: true });
      }
    }
  });
}

function describe(label: string, result: RunResult): string {
  const lines = [result.output.trim()];
  if (result.error) lines.push(`[${label}: could not run: ${result.error}]`);
  if (result.timedOut) lines.push(`[${label}: stopped after exceeding its time limit]`);
  if (result.aborted) lines.push(`[${label}: stopped because the call was cancelled]`);
  if (result.overflow) lines.push(`[${label}: output exceeded ${CAPTURE_LIMIT_BYTES} bytes and was cut off]`);
  if (result.status !== null && result.status !== 0) lines.push(`[${label}: exit ${result.status}]`);
  return lines.filter(Boolean).join("\n") || `[${label}: exit ${result.status ?? "unknown"}]`;
}

function modelText(text: string): { text: string; truncated: boolean } {
  if (Buffer.byteLength(text, "utf8") <= MODEL_OUTPUT_LIMIT) return { text, truncated: false };
  return {
    text: `${Buffer.from(text, "utf8").subarray(0, MODEL_OUTPUT_LIMIT).toString("utf8")}\n[output truncated to ${MODEL_OUTPUT_LIMIT} bytes]`,
    truncated: true,
  };
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
}

// Owned when line 1 of state/.lock names this Pi process or one of its
// ancestors, the same test the watcher extension applies.
function lockOwned(): boolean {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").split("\n")[0].trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return false;
}

function text(message: string, details: Record<string, unknown> = {}) {
  return { content: [{ type: "text" as const, text: message }], details };
}

export default function (pi: ExtensionAPI) {
  if (process.env[ENABLE_ENV] !== "1") return;

  const deliverIntervalMs = positiveInteger("FM_PI_RESTRICTED_DELIVER_INTERVAL_MS", 180_000);
  let ui: Ui;
  let pendingAck: PendingAck | null = null;
  let drainQueue: Promise<unknown> = Promise.resolve();
  let deliverRunning = false;
  let lastBackgroundReport = "";
  let interval: ReturnType<typeof setInterval> | undefined;

  const restrictionRefusal = (): string | undefined => {
    let active: unknown;
    try {
      active = pi.getActiveTools();
    } catch {
      active = undefined;
    }
    if (!Array.isArray(active)) {
      return "restricted supervision refused: this session's active tools could not be read, so its restriction cannot be verified";
    }
    const extra = active.filter((name) => !RESTRICTED_TOOLS.has(String(name)));
    if (extra.length === 0) return undefined;
    return `restricted supervision refused: this session also exposes ${extra.join(", ")}; ` +
      "launch Pi with --no-builtin-tools --no-extensions and only the restricted and watcher extensions";
  };

  const readiness = (): string | undefined => {
    const refusal = restrictionRefusal();
    if (refusal) return refusal;
    if (!lockOwned()) {
      return "restricted supervision refused: this Pi process does not hold this home's session lock, so it must not drain wakes or advance delivery; restart the restricted Pi session to reacquire it";
    }
    return undefined;
  };

  const runDeliver = async (signal?: AbortSignal): Promise<string | null> => {
    if (deliverRunning) return null;
    deliverRunning = true;
    try {
      const refusal = readiness();
      if (refusal) return refusal;
      return describe("fm_deliver", await runEngine(deliverScript, [], DELIVER_TIMEOUT_MS, signal));
    } finally {
      deliverRunning = false;
    }
  };

  // Background passes report to the captain's screen, not to the model, and
  // only when something happened that differs from the last report.
  const deliverInBackground = (): void => {
    void runDeliver().then((report) => {
      if (report === null || report === "deliver: nothing to do" || report === lastBackgroundReport) return;
      lastBackgroundReport = report;
      const trouble = /refused|could not|skipped|\[fm_deliver:/.test(report);
      ui?.notify?.(report, trouble ? "warning" : "info");
    });
  };

  pi.on("session_start", async (_event, ctx) => {
    ui = ctx?.ui;
    const refusal = restrictionRefusal();
    if (refusal) {
      ui?.notify?.(refusal, "error");
      return;
    }
    if (!lockOwned()) {
      const result = await runEngine(lockScript, [], LOCK_TIMEOUT_MS);
      if (!lockOwned()) {
        ui?.notify?.(`restricted supervision: the session lock was not acquired; nothing will be drained or delivered\n${describe("fm-lock", result)}`, "error");
        return;
      }
    }
    // No pass runs here: the watcher extension arms in its own session_start
    // after this one, and a pass before its first beacon would only report the
    // watcher as down. The interval and the end of each agent run cover it.
    if (!interval) {
      interval = setInterval(deliverInBackground, deliverIntervalMs);
      interval.unref?.();
    }
  });

  pi.on("session_shutdown", async () => {
    if (interval) clearInterval(interval);
    interval = undefined;
  });

  pi.on("agent_end", async (_event, ctx) => {
    ui = ctx?.ui ?? ui;
    deliverInBackground();
  });

  pi.registerTool({
    name: "fm_drain",
    label: "Drain firstmate wakes",
    description:
      "Restricted replacement for bin/fm-wake-drain.sh. Without arguments it presents this home's queued wake records. " +
      "With acknowledge: true it runs exactly the acknowledgement its previous presentation printed; call that only after handling everything presented. " +
      "It accepts no other input and cannot run any other command.",
    promptSnippet: "Present queued firstmate wakes, then acknowledge them after handling.",
    promptGuidelines: [
      "When a notification says to run bin/fm-wake-drain.sh, call fm_drain instead.",
      "After handling everything fm_drain presented, call fm_drain with acknowledge: true once; never acknowledge before handling.",
    ],
    parameters: Type.Object(
      { acknowledge: Type.Optional(Type.Boolean()) },
      { additionalProperties: false },
    ),
    executionMode: "sequential",
    execute: async (_toolCallId, params, signal) => {
      const run = drainQueue.then(async () => {
        const refusal = readiness();
        if (refusal) return text(refusal, { refused: true });
        if (params?.acknowledge === true) {
          const ack = pendingAck;
          if (!ack) {
            return text("fm_drain: nothing to acknowledge; no presentation from this session is awaiting acknowledgement. Call fm_drain without arguments first.");
          }
          const result = await runEngine(
            drainScript,
            ["--ack-through", ack.through, "--recovery-generation", ack.generation],
            DRAIN_TIMEOUT_MS,
            signal,
          );
          if (result.status === 0) pendingAck = null;
          const body = result.status === 0 && !result.output.trim()
            ? `fm_drain: acknowledged the presented wakes through ${ack.through}`
            : describe("fm_drain", result);
          const redirect = body.includes("bin/fm-wake-drain.sh")
            ? "\n[fm_drain: where this names bin/fm-wake-drain.sh, call fm_drain instead]"
            : "";
          return text(`${modelText(body).text}${redirect}`, { acknowledged: result.status === 0 });
        }
        const result = await runEngine(drainScript, [], DRAIN_TIMEOUT_MS, signal);
        const shown = modelText(describe("fm_drain", result));
        let ack: PendingAck | null = null;
        for (const match of result.output.matchAll(ACK_LINE)) ack = { through: match[1], generation: match[2] };
        const complete = !result.overflow && !result.timedOut && !result.aborted && !result.error && !shown.truncated;
        pendingAck = complete ? ack : null;
        let note = "";
        if (pendingAck) {
          note = "\n[fm_drain: after handling everything above, call fm_drain with acknowledge: true to run that acknowledgement]";
        } else if (ack) {
          note = "\n[fm_drain: this presentation was incomplete, so no acknowledgement was stored and every presented wake stays queued]";
        }
        return text(`${shown.text}${note}`, { acknowledgementPending: pendingAck !== null });
      });
      drainQueue = run.catch(() => undefined);
      return run;
    },
  });

  pi.registerTool({
    name: "fm_deliver",
    label: "Advance firstmate delivery",
    description:
      "Runs one delivery pass now: arms merge monitoring for a task whose record shows exactly one ready change, and cleans up a task whose change the merge monitor confirmed merged, never forcing. " +
      "The same pass also runs automatically every few minutes and after each turn. " +
      "It accepts no input and cannot merge, dispatch, edit files, or run any other command.",
    promptSnippet: "Run one deterministic delivery pass now.",
    parameters: Type.Object({}, { additionalProperties: false }),
    executionMode: "sequential",
    execute: async (_toolCallId, _params, signal) => {
      const report = await runDeliver(signal);
      return text(modelText(report ?? "fm_deliver: a delivery pass is already running; this call was skipped").text);
    },
  });
}
