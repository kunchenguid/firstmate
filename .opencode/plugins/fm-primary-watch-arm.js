import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

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
const AWAY_RESUME_POLL_MS = positiveInteger("FM_WATCH_AFK_RESUME_POLL_MS", 250);

let child = null;
let armStatus = "idle";
let retryTimer = null;
let retryFailures = 0;
let awayResumeTimer = null;
let awayResumeContext = null;
let launchInFlight = null;
let restorationInFlight = null;
let armClose = new WeakMap();
let armReadiness = new WeakMap();

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

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
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

// Away mode: while state/.afk exists the away-mode daemon owns the watcher and
// classifies every wake in bash, so this plugin arms nothing and delivers no
// ordinary wake. Read live on every decision rather than cached, because the
// captain enters and leaves away mode inside one OpenCode session.
// bin/fm-watch-arm.sh's "AWAY MODE" header owns the contract.
function awayModeActive(paths) {
  return existsSync(`${paths.state}/.afk`);
}

function shouldArm(paths) {
  if (awayModeActive(paths)) return false;
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
  // Away mode was entered between this spawn and the arm's own gate. The arm
  // refused rather than taking the watcher singleton from the daemon, which is a
  // benign close, not a failure.
  const stoodDown = combined.split(/\r?\n/).find((line) => /^watcher: stood-down\b/.test(line));
  if (stoodDown) return { kind: "stood-down", message: stoodDown };
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

async function sendPrompt(paths, client, sessionID, text, suppressWhileAway = false) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  // Accepted AFK-entry residual: activation after this final check can allow
  // at most one extra wake before delivery. Point-in-time checks cannot close
  // the race without the deferred cross-component AFK-transition handshake.
  // The durable queue prevents loss, and established-away-state cases park.
  if (suppressWhileAway && awayModeActive(paths)) return;
  await client.session.promptAsync({
    path: { id: sessionID },
    body: {
      parts: [{ type: "text", text: encoded }],
    },
  });
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(paths, client, sessionID, reason, suppressWhileAway = false) {
  void sendPrompt(paths, client, sessionID, wakePrompt(reason), suppressWhileAway).catch(() => {
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

async function restoreAfterActionableClose(paths, sessionID, client, predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    // Away mode reclaims the watcher for the daemon; there is no successor to
    // restore here and no failure to report.
    if (awayModeActive(paths)) {
      parkForAwayResume(paths, sessionID, client, predecessorArmPid);
      return { kind: "parked" };
    }
    const { status, armChild } = await ensureArm(paths, sessionID, client, predecessorArmPid, true);
    if (status === "armed") return { kind: "restored", failure: "" };
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return { kind: "restored", failure: "" };
    failure = restorationFailure(status);
    if (!(await retireArm(armChild))) {
      setArmStatus("failed");
      return {
        kind: "restored",
        failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms`,
      };
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus("failed");
  return {
    kind: "restored",
    failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries`,
  };
}

function parkForAwayResume(paths, sessionID, client, predecessorArmPid) {
  awayResumeContext = { paths, sessionID, client, predecessorArmPid };
  if (awayResumeTimer) return;
  const timer = setTimeout(() => {
    if (awayResumeTimer === timer) awayResumeTimer = null;
    const context = awayResumeContext;
    if (!context) return;
    if (awayModeActive(context.paths)) {
      parkForAwayResume(context.paths, context.sessionID, context.client, context.predecessorArmPid);
      return;
    }
    void sessionOwnsLock(context.paths).then((ownsLock) => {
      if (awayResumeContext !== context) return;
      if (!ownsLock) {
        awayResumeContext = null;
        return;
      }
      if (awayModeActive(context.paths)) {
        parkForAwayResume(context.paths, context.sessionID, context.client, context.predecessorArmPid);
        return;
      }
      awayResumeContext = null;
      void ensureArm(context.paths, context.sessionID, context.client, context.predecessorArmPid).then((status) => {
        if (awayModeActive(context.paths)) {
          parkForAwayResume(context.paths, context.sessionID, context.client, context.predecessorArmPid);
          return;
        }
        if (["armed", "starting", "wake", "existing", "retrying", "not-needed"].includes(status)) return;
        surfaceFailure(context.paths, context.client, context.sessionID, `watcher: FAILED - OpenCode could not resume continuity after away mode (${status})`, true);
      });
    });
  }, AWAY_RESUME_POLL_MS);
  timer.unref();
  awayResumeTimer = timer;
}

async function scheduleRetry(paths, sessionID, client, reason, predecessorArmPid) {
  if (child || retryTimer) return;
  if (awayModeActive(paths)) {
    parkForAwayResume(paths, sessionID, client, predecessorArmPid);
    return;
  }
  if (!(await sessionOwnsLock(paths))) {
    setArmStatus("failed");
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`, true);
    return;
  }
  if (awayModeActive(paths)) {
    parkForAwayResume(paths, sessionID, client, predecessorArmPid);
    return;
  }
  retryFailures += 1;
  if (retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus("failed");
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`, true);
    return;
  }
  setArmStatus("retrying");
  const timer = setTimeout(() => {
    if (retryTimer === timer) retryTimer = null;
    if (awayModeActive(paths)) {
      retryFailures = 0;
      setArmStatus("stood-down");
      parkForAwayResume(paths, sessionID, client, predecessorArmPid);
      return;
    }
    void ensureArm(paths, sessionID, client, predecessorArmPid).then((status) => {
      if (awayModeActive(paths)) {
        retryFailures = 0;
        setArmStatus("stood-down");
        parkForAwayResume(paths, sessionID, client, predecessorArmPid);
        return;
      }
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`, true);
    });
  }, retryDelay(retryFailures));
  timer.unref();
  retryTimer = timer;
}

function spawnArm(paths, sessionID, client, predecessorArmPid = "") {
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
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeArmOutput(stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (awayModeActive(paths)) {
      // Away mode owns supervision. Stand down instead of re-arming: the daemon
      // reclaims the watcher singleton and classifies this wake in bash, and the
      // wake itself is already durable in state/.wake-queue. Delivering it here
      // is the firstmate turn away mode exists to save. A real arm failure still
      // surfaces once, with no retry loop behind it.
      retryFailures = 0;
      setArmStatus("stood-down");
      if (classification.kind === "failure" && !restorationInFlight) {
        surfaceFailure(paths, client, sessionID, classification.message);
      }
      parkForAwayResume(paths, sessionID, client, predecessor);
      return;
    }
    // A stand-down close with away mode already over means the flag was cleared
    // mid-cycle: fall through to the ordinary bounded retry so the primary does
    // not stay blind, and never report it as a failure.
    if (classification.kind === "actionable") {
      retryFailures = 0;
      setArmStatus("wake");
      const previousRestoration = restorationInFlight;
      const restoration = previousRestoration
        ? previousRestoration.catch(() => ({ kind: "restored", failure: "" })).then(() => restoreAfterActionableClose(paths, sessionID, client, predecessor))
        : restoreAfterActionableClose(paths, sessionID, client, predecessor);
      restorationInFlight = restoration;
      void restoration.then((result) => {
        if (restorationInFlight === restoration) restorationInFlight = null;
        if (result.kind === "parked") return undefined;
        // Away mode can begin while restoration is in flight; the wake is
        // durable in state/.wake-queue and belongs to the daemon now.
        if (awayModeActive(paths)) {
          parkForAwayResume(paths, sessionID, client, predecessor);
          return undefined;
        }
        const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
        return sendPrompt(paths, client, sessionID, wakePrompt(message), true);
      }).catch(() => {
      });
      return;
    }
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(paths, sessionID, client, classification.message, predecessor);
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    const spawnFailure = `watcher: FAILED - OpenCode arm child failed: ${error.message}`;
    if (awayModeActive(paths)) {
      // Away mode owns supervision, so surface the failure once and let the
      // daemon keep the watcher rather than opening a retry loop.
      retryFailures = 0;
      setArmStatus("stood-down");
      surfaceFailure(paths, client, sessionID, spawnFailure);
      parkForAwayResume(paths, sessionID, client, String(armChild.pid ?? ""));
      return;
    }
    void scheduleRetry(paths, sessionID, client, spawnFailure, String(armChild.pid ?? ""));
  });
  return armChild;
}

async function beginArm(paths, sessionID, client, predecessorArmPid) {
  if (!sessionID) return { status: "skipped", armChild: null };
  if (!(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
  if (!(await sessionOwnsLock(paths))) return { status: "read-only", armChild: null };
  if (child) return { status: "existing", armChild: child };
  if (retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
  return { status: "spawned", armChild: spawnArm(paths, sessionID, client, predecessorArmPid) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(paths, sessionID, client, predecessorArmPid = "", includeArmChild = false) {
  let launchResult = null;
  if (!launchInFlight) {
    const launch = beginArm(paths, sessionID, client, predecessorArmPid);
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

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(root);
  globalThis[COORDINATOR_KEY] = {
    ensureArmed: (sessionID, activeClient) => ensureArm(paths, sessionID, activeClient ?? client),
  };

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      void ensureArm(paths, sessionID, client);
    },
  };
};
