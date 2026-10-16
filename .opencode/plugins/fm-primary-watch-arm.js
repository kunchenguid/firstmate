import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

// Supervision host: a home opted in with config/supervision-host
// (docs/configuration.md "Supervision host" owns the gate, which
// bin/fm-supervision-engine-lib.sh enabled answers; config/supervision-host-off opts out) spawns
// bin/fm-supervision-host.sh park in the arm's place, which takes
// away-posture wakes itself and closes only when main is needed; its header
// owns the output read here. A "supervision-host:" line is actionable like a
// wake line, and the delivered message carries every such line in order while
// wake lines keep an eight-line cap. The host prints the first cycle's status
// line as soon as it is verified, so readiness and the handling handoff work
// as they do for the arm, with a longer readiness budget for the host's own
// startup. On a home that does not run the host nothing below changes.
const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const ARM_READY_TIMEOUT_DEFAULT_MS = process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS);
const HOST_READY_TIMEOUT_MS = Math.max(ARM_READY_TIMEOUT_MS, 30000);
const WAKE_LINE = /^(signal:|stale:|check:|heartbeat($|:))/;
const HOST_LINE = /^supervision-host:/;
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

// One arming state per supervising home, anchored on globalThis instead of this
// module's scope. The host can load this plugin more than once in one process
// (a reload, or one load per session), and independent module states let
// overlapping wake deliveries each spawn their own successor arm; because each
// successor used to restart the home's watcher, the second spawn stopped the
// healthy cycle the first had just started. Every load for the same home shares
// one arm child, one launch, and one retry schedule through this state, so a
// delivery is deduplicated to exactly one successor no matter how many
// subscribers observe it. docs/watcher-continuity.md "Pi, omp, and OpenCode
// successor start" owns the one-successor contract.
function sharedCoordinator() {
  const existing = globalThis[COORDINATOR_KEY];
  if (existing && existing.homes instanceof Map) return existing;
  const coordinator = { homes: new Map(), ensureArmed: () => "idle" };
  globalThis[COORDINATOR_KEY] = coordinator;
  return coordinator;
}

function homeStateFor(paths) {
  const coordinator = sharedCoordinator();
  let state = coordinator.homes.get(paths.home);
  if (!state) {
    state = {
      paths,
      child: null,
      deliveryTarget: null,
      armStatus: "idle",
      retryTimer: null,
      retryFailures: 0,
      launchInFlight: null,
      restorationInFlight: null,
      armClose: new WeakMap(),
      armReadiness: new WeakMap(),
      armRecovery: new WeakMap(),
      armHostMode: new WeakMap(),
    };
    coordinator.homes.set(paths.home, state);
  }
  return state;
}

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(state, status) {
  state.armStatus = status;
}

function waitForArmReady(state, armChild) {
  const readiness = state.armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  const timeout = state.armHostMode.get(armChild) ? HOST_READY_TIMEOUT_MS : ARM_READY_TIMEOUT_MS;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), timeout);
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

// bin/fm-supervision-lib.sh's fm_supervision_needed is the single owner of the
// arm condition set (the turn-end guard decides with the same shared
// predicate), so this plugin can never disagree with the guard again. Away
// mode stays a local decline: its daemon owns supervision. X-mode homes arm
// before their relay poll is registered in the state directory.
function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  return supervisionNeeded(paths);
}

// fm_supervision_needed <state-dir> exits 0 exactly when the shared predicate
// says the home needs supervision; exit 0 means arm here.
function supervisionNeeded(paths) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      '. "$1/bin/fm-supervision-lib.sh" && fm_supervision_needed "$2"',
      "fm-primary-watch-arm",
      paths.root,
      paths.state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

function sessionLockPid(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return "";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "";
  return lockPid;
}

async function sessionOwnsLock(paths, expectedLockPid = "") {
  const lockPid = sessionLockPid(paths);
  if (!lockPid || (expectedLockPid && lockPid !== expectedLockPid)) return false;
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

// An away record, never quiet mode's (bin/fm-afk-contract.sh mode owns that
// reading): a record whose mode cannot be read as quiet reads as away.
function awayRecordPresent(paths) {
  if (!existsSync(`${paths.state}/.afk-contract`)) return false;
  const result = spawnSync("bash", [`${paths.root}/bin/fm-afk-contract.sh`, "mode"], {
    encoding: "utf8",
    env: { ...process.env, FM_STATE_OVERRIDE: paths.state },
  });
  return String(result.stdout || "").trim() !== "quiet";
}

// Whether this home runs the supervision host for an OpenCode primary; the
// gate's owner answers, and a query that cannot run reads as no host.
function hostModeEnabled(paths) {
  const result = spawnSync("bash", [`${paths.root}/bin/fm-supervision-engine-lib.sh`, "enabled", paths.config, "opencode"], {
    stdio: "ignore",
  });
  return result.status === 0;
}

// The host-mode wake message: every "supervision-host:" line in order, wake
// lines capped at eight, and the away note while an away record exists.
function hostWakeMessage(paths, combined) {
  let shown = 0;
  const lines = combined.split(/\r?\n/).filter((line) => {
    if (HOST_LINE.test(line)) return true;
    if (WAKE_LINE.test(line) && shown < 8) {
      shown += 1;
      return true;
    }
    return false;
  });
  if (lines.length === 0) return "";
  if (awayRecordPresent(paths)) {
    lines.push("This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.");
  }
  return lines.join("\n");
}

function classifyArmClose(paths, hostMode, stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  if (hostMode) {
    const message = hostWakeMessage(paths, combined);
    if (message) return { kind: "actionable", message };
    const stoodDown = combined.split(/\r?\n/).find((line) => /^supervision-host stood down:/.test(line));
    if (stoodDown) return { kind: "failure", message: `watcher: FAILED - ${stoodDown}` };
  }
  const reason = combined.split(/\r?\n/).find((line) => WAKE_LINE.test(line));
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
    const script = hostMode ? "fm-supervision-host.sh" : "fm-watch-arm.sh";
    return {
      kind: "failure",
      message: `watcher: FAILED - ${script} exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(state, hostMode, stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => WAKE_LINE.test(line) || (hostMode && HOST_LINE.test(line)))) {
    setArmStatus(state, "wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus(state, "armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus(state, "external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus(state, "failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(paths, client, sessionID, text) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  await client.session.promptAsync({
    path: { id: sessionID },
    body: {
      parts: [{ type: "text", text: encoded }],
    },
  });
}

async function sendWakePrompt(state, fallbackTarget, text) {
  const owner = state.deliveryTarget;
  const ownerIsCurrent = owner && await sessionOwnsLock(state.paths, owner.lockPid);
  const target = ownerIsCurrent ? owner : fallbackTarget;
  if (!ownerIsCurrent) {
    console.warn(`watcher: OpenCode wake owner unresolved; falling back to arming session ${fallbackTarget.sessionID}`);
  }
  await sendPrompt(state.paths, target.client, target.sessionID, text);
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

function confirmHandlingDeliveryWithRetry(state, recovery) {
  const snapshot = () => state.armRecovery.get(state.child) ?? recovery;
  const first = confirmHandlingDelivery(state.paths, snapshot());
  if (first.ok) return first;
  return confirmHandlingDelivery(state.paths, snapshot());
}

async function deliverActionableWake(state, client, sessionID, message, recovery) {
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(state, recovery);
    if (!confirmed.ok) {
      if (recovery.watcherPid) {
        try {
          process.kill(Number(recovery.watcherPid), 0);
        } catch {
          await retireArm(state, state.child);
        }
      }
      await sendWakePrompt(state, { client, sessionID }, wakePrompt(`${message}\n\n${confirmed.detail}`));
      return;
    }
  }
  await sendWakePrompt(state, { client, sessionID }, wakePrompt(message));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(state, client, sessionID, reason) {
  void sendWakePrompt(state, { client, sessionID }, wakePrompt(reason)).catch(() => {
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

async function retireArm(state, armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = state.armClose.get(armChild);
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

async function restoreAfterActionableClose(state, sessionID, client, predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    const { status, armChild } = await ensureArm(state, sessionID, client, predecessorArmPid, true);
    if (status === "armed") return { failure: "", recovery: state.armRecovery.get(armChild) };
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return { failure: "", recovery: state.armRecovery.get(armChild) };
    failure = restorationFailure(status);
    if (!(await retireArm(state, armChild))) {
      setArmStatus(state, "failed");
      return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms` };
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus(state, "failed");
  return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries` };
}

async function scheduleRetry(state, sessionID, client, reason, predecessorArmPid) {
  if (state.child || state.retryTimer) return;
  if (!(await sessionOwnsLock(state.paths))) {
    setArmStatus(state, "failed");
    surfaceFailure(state, client, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  state.retryFailures += 1;
  if (state.retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus(state, "failed");
    surfaceFailure(state, client, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus(state, "retrying");
  const timer = setTimeout(() => {
    if (state.retryTimer === timer) state.retryTimer = null;
    void ensureArm(state, sessionID, client, predecessorArmPid).then((status) => {
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(state, client, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    });
  }, retryDelay(state.retryFailures));
  timer.unref();
  state.retryTimer = timer;
}

function spawnArm(state, sessionID, client, predecessorArmPid = "") {
  const paths = state.paths;
  setArmStatus(state, "starting");
  const hostMode = hostModeEnabled(paths);
  const env = {
    ...process.env,
    FM_HOME: paths.home,
    FM_ROOT_OVERRIDE: paths.root,
    FM_CONFIG_OVERRIDE: paths.config,
    FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  if (hostMode) env.FM_SUPERVISION_HOST_PRIMARY = "opencode";
  const command = hostMode ? '"$FM_ROOT_OVERRIDE/bin/fm-supervision-host.sh" park' : '"$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh"';
  const armChild = spawn("bash", ["-lc", `config_dir="\${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec ${command}`], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  state.armHostMode.set(armChild, hostMode);
  state.child = armChild;
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  state.armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  state.armClose.set(armChild, closed);
  const releaseChild = () => {
    if (state.child === armChild) state.child = null;
  };
  const observeRecovery = () => {
    const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) state.armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeRecovery();
    observeArmOutput(state, hostMode, stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeRecovery();
    observeArmOutput(state, hostMode, stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(paths, hostMode, stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "actionable") {
      if (state.restorationInFlight) return;
      state.retryFailures = 0;
      setArmStatus(state, "wake");
      const restoration = restoreAfterActionableClose(state, sessionID, client, predecessor);
      state.restorationInFlight = restoration;
      void restoration.then(async (result) => {
        try {
          const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
          await deliverActionableWake(state, client, sessionID, message, result.recovery);
        } finally {
          if (state.restorationInFlight === restoration) state.restorationInFlight = null;
        }
      }).catch((error) => {
        if (state.restorationInFlight === restoration) state.restorationInFlight = null;
        surfaceFailure(
          state,
          client,
          sessionID,
          `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
        );
      });
      return;
    }
    if (state.restorationInFlight) {
      setArmStatus(state, "failed");
      return;
    }
    void scheduleRetry(state, sessionID, client, classification.message, predecessor);
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (state.restorationInFlight) {
      setArmStatus(state, "failed");
      return;
    }
    void scheduleRetry(
      state,
      sessionID,
      client,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
    );
  });
  return armChild;
}

function beginArm(state, sessionID, client, predecessorArmPid) {
  if (state.child) return { status: "existing", armChild: state.child };
  if (state.retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(state.paths)) return { status: "not-needed", armChild: null };
  return { status: "spawned", armChild: spawnArm(state, sessionID, client, predecessorArmPid) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(state, sessionID, client, predecessorArmPid = "", includeArmChild = false, updateDeliveryTarget = false) {
  if (!sessionID) return armAttempt("skipped", null, includeArmChild);
  if (!(await isPrimaryRoot(state.paths.root, state.paths.home))) {
    return armAttempt("not-primary", null, includeArmChild);
  }
  const lockPid = sessionLockPid(state.paths);
  if (!lockPid || !(await sessionOwnsLock(state.paths, lockPid))) {
    return armAttempt("read-only", null, includeArmChild);
  }
  if (updateDeliveryTarget && client) state.deliveryTarget = { client, sessionID, lockPid };

  let launchResult = null;
  if (!state.launchInFlight) {
    const launch = Promise.resolve().then(() => beginArm(state, sessionID, client, predecessorArmPid));
    state.launchInFlight = launch;
    try {
      launchResult = await launch;
    } finally {
      if (state.launchInFlight === launch) state.launchInFlight = null;
    }
  } else {
    launchResult = await state.launchInFlight;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  return armAttempt(await waitForArmReady(state, armChild), armChild, includeArmChild);
}

async function ensureArmForSession(state, sessionID, client) {
  return ensureArm(state, sessionID, client, "", false, true);
}

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(root);
  const state = homeStateFor(paths);
  sharedCoordinator().ensureArmed = (sessionID, activeClient) => ensureArmForSession(state, sessionID, activeClient ?? client);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      void ensureArmForSession(state, sessionID, client);
    },
  };
};
