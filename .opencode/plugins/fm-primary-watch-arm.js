import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { executionEnded, pluginRoot, subscribeToEvents } from "./lib/fm-v2-plugin.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const ARM_READY_TIMEOUT_DEFAULT_MS = process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

let child = null;
let armStatus = "idle";
let retryTimer = null;
let retryFailures = 0;
let launchInFlight = null;
let restorationInFlight = null;
let armClose = new WeakMap();
let armReadiness = new WeakMap();
let armRecovery = new WeakMap();
let activeGeneration = 0;

function generationIsActive(generation) {
  return generation === activeGeneration;
}

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(status) {
  armStatus = status;
}

function waitForArmReady(armChild) {
  const readiness = armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), ARM_READY_TIMEOUT_MS);
    timer.unref();
    void readiness.then((status) => {
      clearTimeout(timer);
      resolve(status);
    });
  });
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  try {
    return readdirSync(paths.state).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

async function sessionOwnsLock(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    const result = await runProcess("ps", ["-o", "ppid=", "-p", pid]);
    if (result.code !== 0) return false;
    pid = result.stdout.trim();
    if (!pid || pid === "1") return false;
  }
  return false;
}

function classifyArmClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  const reason = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line))) {
    setArmStatus("wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus("armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus("external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus("failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(paths, ctx, sessionID, text) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  await ctx.session.prompt({ sessionID, text: encoded });
}

function confirmHandlingDelivery(paths, recovery) {
  try {
    const result = spawnSync(
      "bash",
      [`${paths.root}/bin/fm-watch-arm.sh`, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
      {
        cwd: paths.root,
        encoding: "utf8",
        env: { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state, FM_ROOT_OVERRIDE: paths.root },
      },
    );
    if (result.status === 0) return { ok: true, detail: "" };
    const stderr = String(result.stderr || "").trim();
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${String(error?.message ?? error)}`,
    };
  }
}

function confirmHandlingDeliveryWithRetry(paths, recovery) {
  const snapshot = () => armRecovery.get(child) ?? recovery;
  const first = confirmHandlingDelivery(paths, snapshot());
  if (first.ok) return first;
  return confirmHandlingDelivery(paths, snapshot());
}

async function deliverActionableWake(paths, ctx, sessionID, message, recovery, generation) {
  if (!generationIsActive(generation)) return;
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(paths, recovery);
    if (!confirmed.ok) {
      if (recovery.watcherPid) {
        try {
          process.kill(Number(recovery.watcherPid), 0);
        } catch {
          await retireArm(child);
        }
      }
      if (generationIsActive(generation)) {
        await sendPrompt(paths, ctx, sessionID, wakePrompt(`${message}\n\n${confirmed.detail}`));
      }
      return;
    }
  }
  if (generationIsActive(generation)) await sendPrompt(paths, ctx, sessionID, wakePrompt(message));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(paths, ctx, sessionID, reason) {
  void sendPrompt(paths, ctx, sessionID, wakePrompt(reason)).catch(() => {
    // OpenCode owns delivery errors; continuity restoration never waits on prompting.
  });
}

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function waitForRetry(attempt) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, retryDelay(attempt));
    timer.unref();
  });
}

async function retireArm(armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = armClose.get(armChild);
  if (!closed) return false;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ARM_RETIRE_TIMEOUT_MS);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function restorationFailure(status) {
  if (status === "read-only") {
    return "watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock";
  }
  return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
}

async function restoreAfterActionableClose(paths, sessionID, ctx, predecessorArmPid, generation) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    if (!generationIsActive(generation)) return { failure: "", recovery: null };
    const { status, armChild } = await ensureArm(paths, sessionID, ctx, predecessorArmPid, true, generation);
    if (status === "armed") return { failure: "", recovery: armRecovery.get(armChild) };
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return { failure: "", recovery: armRecovery.get(armChild) };
    failure = restorationFailure(status);
    if (!(await retireArm(armChild))) {
      setArmStatus("failed");
      return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms` };
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus("failed");
  return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries` };
}

async function scheduleRetry(paths, sessionID, ctx, reason, predecessorArmPid, generation) {
  if (!generationIsActive(generation)) return;
  if (child || retryTimer) return;
  if (!(await sessionOwnsLock(paths))) {
    if (!generationIsActive(generation)) return;
    setArmStatus("failed");
    surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  if (!generationIsActive(generation)) return;
  retryFailures += 1;
  if (retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus("failed");
    surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus("retrying");
  const timer = setTimeout(() => {
    if (retryTimer === timer) retryTimer = null;
    if (!generationIsActive(generation)) return;
    void ensureArm(paths, sessionID, ctx, predecessorArmPid, false, generation).then((status) => {
      if (!generationIsActive(generation)) return;
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(paths, ctx, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    });
  }, retryDelay(retryFailures));
  timer.unref();
  retryTimer = timer;
}

function spawnArm(paths, sessionID, ctx, predecessorArmPid = "", generation) {
  setArmStatus("starting");
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
    FM_CONFIG_OVERRIDE: paths.config,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  const armChild = spawn("bash", ["-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" --restart'], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child = armChild;
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  armClose.set(armChild, closed);
  const releaseChild = () => {
    if (child === armChild) child = null;
  };
  const observeRecovery = () => {
    const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeRecovery();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeRecovery();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    if (!generationIsActive(generation)) return;
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "actionable") {
      if (restorationInFlight) return;
      retryFailures = 0;
      setArmStatus("wake");
      const restoration = restoreAfterActionableClose(paths, sessionID, ctx, predecessor, generation);
      restorationInFlight = restoration;
      void restoration.then(async (result) => {
        try {
          const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
          await deliverActionableWake(paths, ctx, sessionID, message, result.recovery, generation);
        } finally {
          if (restorationInFlight === restoration) restorationInFlight = null;
        }
      }).catch((error) => {
        if (restorationInFlight === restoration) restorationInFlight = null;
        if (!generationIsActive(generation)) return;
        surfaceFailure(
          paths,
          ctx,
          sessionID,
          `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
        );
      });
      return;
    }
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(paths, sessionID, ctx, classification.message, predecessor, generation);
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (!generationIsActive(generation)) return;
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(
      paths,
      sessionID,
      ctx,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
      generation,
    );
  });
  return armChild;
}

async function beginArm(paths, sessionID, ctx, predecessorArmPid, generation) {
  if (!generationIsActive(generation)) return { status: "disposed", armChild: null };
  if (!sessionID) return { status: "skipped", armChild: null };
  if (!(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
  if (!generationIsActive(generation)) return { status: "disposed", armChild: null };
  if (!(await sessionOwnsLock(paths))) return { status: "read-only", armChild: null };
  if (!generationIsActive(generation)) return { status: "disposed", armChild: null };
  if (child) return { status: "existing", armChild: child };
  if (retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
  return { status: "spawned", armChild: spawnArm(paths, sessionID, ctx, predecessorArmPid, generation) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(paths, sessionID, ctx, predecessorArmPid = "", includeArmChild = false, generation = activeGeneration) {
  if (!generationIsActive(generation)) return armAttempt("disposed", null, includeArmChild);
  let launchResult = null;
  if (!launchInFlight) {
    const launch = beginArm(paths, sessionID, ctx, predecessorArmPid, generation);
    launchInFlight = launch;
    try {
      launchResult = await launch;
    } finally {
      if (launchInFlight === launch) launchInFlight = null;
    }
  } else {
    launchResult = await launchInFlight;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  return armAttempt(await waitForArmReady(armChild), armChild, includeArmChild);
}

async function disposeWatchArm(generation, coordinator) {
  if (!generationIsActive(generation)) return;
  activeGeneration += 1;
  if (retryTimer) clearTimeout(retryTimer);
  retryTimer = null;
  retryFailures = 0;
  launchInFlight = null;
  restorationInFlight = null;
  const armChild = child;
  child = null;
  setArmStatus("idle");
  if (globalThis[COORDINATOR_KEY] === coordinator) delete globalThis[COORDINATOR_KEY];
  await retireArm(armChild);
  armClose = new WeakMap();
  armReadiness = new WeakMap();
  armRecovery = new WeakMap();
}

export async function createWatchArmHandler(ctx, generation = ++activeGeneration) {
  const root = pluginRoot(ctx);
  const paths = effectivePaths(root);
  const coordinator = {
    ensureArmed: (sessionID, activeContext) => ensureArm(paths, sessionID, activeContext ?? ctx, "", false, generation),
  };
  globalThis[COORDINATOR_KEY] = coordinator;

  const handleEvent = async (event) => {
    if (!generationIsActive(generation)) return;
    if (!executionEnded(event)) return;
    const sessionID = event.data.sessionID;
    if (!sessionID) return;
    void ensureArm(paths, sessionID, ctx, "", false, generation);
  };
  handleEvent.coordinator = coordinator;
  handleEvent.generation = generation;
  return handleEvent;
}

export default {
  id: "firstmate.primary-watch-arm",
  async setup(ctx) {
    if (activeGeneration) {
      await disposeWatchArm(activeGeneration, globalThis[COORDINATOR_KEY]);
    }
    const handleEvent = await createWatchArmHandler(ctx);
    const unsubscribe = subscribeToEvents(ctx, handleEvent);
    return async () => {
      unsubscribe();
      await disposeWatchArm(handleEvent.generation, handleEvent.coordinator);
    };
  },
};
