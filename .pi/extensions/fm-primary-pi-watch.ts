// Firstmate primary watcher bridge for Pi.
//
// Session-generation ownership (stated once here):
// Pi emits session_shutdown for ordinary same-process replacements (/new, /resume,
// /fork, reload) as well as terminal quit. This extension binds one generation per
// session activation. Only the active live generation may start, stop, rearm, or
// clear the arm child. Replacement session_start (or a fresh factory bind) activates
// a new live generation so monitoring can arm again without restarting Pi. Terminal
// quit leaves the final generation stopped so late callbacks cannot rearm. Stale
// callbacks from a prior generation are no-ops against the active replacement.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Box, Container, Text, type Component } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  type CalmPresentationState,
  calmTranscriptClassIsVisible,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
} from "./lib/fm-calm-visibility.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type WatchToolShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

type WatchToolRenderContext = {
  isError: boolean;
  isPartial: boolean;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
};

function refreshWatchToolShell(
  state: WatchToolShellState,
  theme: Theme,
  context: WatchToolRenderContext,
): Box {
  const background = context.isPartial
    ? (text: string) => theme.bg("toolPendingBg", text)
    : context.isError
      ? (text: string) => theme.bg("toolErrorBg", text)
      : (text: string) => theme.bg("toolSuccessBg", text);
  const shell = state.shell ?? new Box(1, 1, background);
  state.shell = shell;
  shell.setBgFn(background);
  shell.clear();
  if (state.call) shell.addChild(state.call);
  if (state.result) shell.addChild(state.result);
  return shell;
}

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_PI_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000,
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_pi again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - Pi session is shutting down";

let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

// Naming the broken away mode on the wake surface, because this extension arming
// the cycle is exactly what keeps the watcher healthy - so fm-guard.sh and the
// turn-end guard never print their banners, and nothing else would report it
// before the next session start. The sentence has one owner in
// bin/fm-wake-lib.sh, reached here through the read-only launcher entry point;
// the flag test short-circuits the spawn outside away mode, and an unreadable
// answer stays silent rather than inventing one.
// The cover is per-call, not per-adapter: a path that just reported this cycle
// broken passes an empty one, so the sentence says nothing covers the home
// instead of naming the mechanism it has just declared dead.
function awayModeDownNotice(cover: string): string {
  if (!existsSync(`${state}/.afk`)) return "";
  const result = spawnSync(
    "bash",
    [`${fmRoot}/bin/fm-afk-launch.sh`, "down-notice", cover],
    {
      encoding: "utf8",
      env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
    },
  );
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason",
  };
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
  };
}

function activateGeneration(generation: SessionGeneration): void {
  activeGeneration = generation;
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function stopGeneration(generation: SessionGeneration): void {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  generation.retryTimer = null;
  if (generation.child) generation.child.kill("SIGTERM");
  generation.child = null;
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

export default function (pi: ExtensionAPI) {
  let generation = createGeneration();
  activateGeneration(generation);

  let calmPresentation: CalmPresentationState = {
    active: false,
    stockExportRendering: false,
  };
  pi.events?.on?.(FIRSTMATE_CALM_PRESENTATION_EVENT, (data) => {
    const next = data as Partial<CalmPresentationState>;
    calmPresentation = {
      active: next.active === true,
      stockExportRendering: next.stockExportRendering === true,
    };
  });
  const calmHides = (itemClass: Parameters<typeof calmTranscriptClassIsVisible>[0]): boolean =>
    calmPresentation.active &&
    !calmPresentation.stockExportRendering &&
    !calmTranscriptClassIsVisible(itemClass);

  async function sendWake(
    owner: SessionGeneration,
    message: string,
    recovery?: { generation: string; watcherPid: string },
    cover = "this extension-owned watcher cycle",
  ): Promise<void> {
    if (!generationIsLive(owner)) return;
    const notice = awayModeDownNotice(cover);
    const content = encodeFirstmateOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.${notice ? `\n\n${notice}` : ""}`,
    );
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
    if (recovery) {
      const result = spawnSync(
        "bash",
        [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
        {
          cwd: fmRoot,
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
        },
      );
      if (result.status !== 0) throw new Error("watcher recovery delivery could not be confirmed");
    }
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message, undefined, "").catch(() => {
      // Pi owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<{
    failure: string;
    recovery?: { generation: string; watcherPid: string };
  }> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm",
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        owner.retryFailures = 0;
        owner.restoring = true;
        void (async () => {
          const restoration = await restoreAfterActionableClose(owner, predecessor);
          if (generationIsLive(owner)) owner.restoring = false;
          if (!generationIsLive(owner)) return;
          const message = restoration.failure ? `${classification.message}\n\n${restoration.failure}` : classification.message;
          await sendWake(owner, message, restoration.recovery, restoration.failure ? "" : "this extension-owned watcher cycle");
        })().catch(() => {
        });
        return;
      }
      if (owner.restoring) return;
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  pi.on?.("session_start", () => {
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopGeneration(generation);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm(generation);
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmHides("assistant-tool-call")) return new Container();
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      }
      const state = context.state as WatchToolShellState;
      state.call = new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      return refreshWatchToolShell(state, theme, context);
    },
    renderResult: (result, _options, theme, context) => {
      if (calmHides("tool-result")) return new Container();
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => item.text)
        .join("\n");
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolOutput", output), 0, 0);
      }
      const state = context.state as WatchToolShellState;
      state.result = output
        ? new Text(theme.fg("toolOutput", output), 0, 0)
        : new Container();
      refreshWatchToolShell(state, theme, context);
      return new Container();
    },
    execute: async () => {
      const result = startArm(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
