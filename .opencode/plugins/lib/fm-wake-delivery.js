import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFirstmateOperationalInput } from "./fm-operational-input.js";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Bounded wake-delivery retry, deliberately small and separate from the arm
// layer's FM_WATCH_REARM_RETRY_* budget: rearm retries own spawning a watcher
// child, these retries own one promptAsync accept, and the two never stack -
// a delivery failure never schedules a rearm and a rearm failure never
// retries delivery. promptAsync resolves at HTTP acceptance (204 "Prompt
// accepted"), so a generous timeout catches only a genuinely wedged client,
// never a slow model turn.
const RETRY_BASE_MS = positiveInteger("FM_WAKE_DELIVERY_RETRY_BASE_MS", 250);
const RETRY_MAX_MS = positiveInteger("FM_WAKE_DELIVERY_RETRY_MAX_MS", 2000);
const RETRY_LIMIT = positiveInteger("FM_WAKE_DELIVERY_RETRY_LIMIT", 2);
const ATTEMPT_TIMEOUT_MS = positiveInteger("FM_WAKE_DELIVERY_TIMEOUT_MS", 10000);

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function errorMessage(error) {
  return String(error?.message ?? error);
}

function singleLine(text) {
  return String(text).replace(/[\t\r\n]+/g, " ").slice(0, 280);
}

function retryDelay(attempt) {
  return Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function sleep(ms) {
  // Deliberately referenced, unlike the arm plugin's idle-timeout timers: the
  // backoff gap has no other live handle, and an unref'd timer lets a bare
  // host process (or a wedged client with no socket) drain its event loop and
  // exit mid-retry instead of completing the bounded delivery attempt.
  return new Promise((resolveSleep) => {
    setTimeout(resolveSleep, ms);
  });
}

export function effectiveHomePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

// Race one promptAsync attempt against its timeout. The losing promise always
// keeps a no-op catch so a late rejection cannot surface as an unhandled
// rejection inside the host TUI. The timer is deliberately referenced: an
// unref'd timer lets an otherwise-idle host drain its event loop and exit
// mid-attempt rather than declare the timeout.
function withAttemptTimeout(promise, ms) {
  return new Promise((resolveAttempt, rejectAttempt) => {
    const timer = setTimeout(() => {
      promise.catch(() => {});
      rejectAttempt(new Error(`promptAsync not accepted within ${ms}ms`));
    }, ms);
    promise.then(
      () => {
        clearTimeout(timer);
        resolveAttempt();
      },
      (error) => {
        clearTimeout(timer);
        rejectAttempt(error);
      },
    );
  });
}

// Declare failure through bin/fm-wake-delivery-alarm.sh, which owns the
// durable state/.wake-delivery-failures record and the wedge-alarm channel
// reuse. Detached and best-effort: this never blocks or breaks the caller's
// own failure handling, and a missing script in a half-updated checkout is
// still recorded by the caller's next bootstrap-visible symptom.
function reportWakeDeliveryFailure(paths, kind, context, reason) {
  const requested = `${paths.root}/bin/fm-wake-delivery-alarm.sh`;
  const script = existsSync(requested) ? requested : `${adapterRoot}/bin/fm-wake-delivery-alarm.sh`;
  const summary = singleLine(`OpenCode ${kind} (${context}) undelivered after ${RETRY_LIMIT + 1} attempt(s): ${reason}`);
  try {
    const child = spawn("bash", [script, "--summary", summary], {
      cwd: paths.root,
      env: {
        ...process.env,
        FM_HOME: paths.home,
        FM_STATE_OVERRIDE: paths.state,
        FM_CONFIG_OVERRIDE: paths.config,
        FM_ROOT_OVERRIDE: paths.root,
      },
      stdio: "ignore",
      detached: true,
    });
    child.on("error", () => {});
    child.unref();
  } catch {
    // Best-effort by contract.
  }
}

// Send already-encoded operational input. Never rejects: it resolves true on
// a confirmed accept and false once the bounded retry budget is exhausted and
// the failure has been declared through the alarm script.
export async function sendEncodedWakePrompt(paths, client, sessionID, kind, encodedText, context) {
  let reason = "unknown failure";
  for (let attempt = 1; attempt <= RETRY_LIMIT + 1; attempt += 1) {
    try {
      await withAttemptTimeout(
        client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: encodedText }],
          },
        }),
        ATTEMPT_TIMEOUT_MS,
      );
      return true;
    } catch (error) {
      reason = singleLine(errorMessage(error));
      if (attempt > RETRY_LIMIT) break;
      await sleep(retryDelay(attempt));
    }
  }
  reportWakeDeliveryFailure(paths, kind, context, reason);
  return false;
}

// Encode plain operational input and deliver it. Never rejects; resolves false
// when even encoding could not run, after declaring that failure too.
export async function sendWakePrompt(paths, client, sessionID, kind, text, context) {
  let encoded;
  try {
    encoded = await encodeFirstmateOperationalInput(paths.root, kind, text);
  } catch (error) {
    reportWakeDeliveryFailure(paths, kind, context, singleLine(`operational-input encode failed: ${errorMessage(error)}`));
    return false;
  }
  return sendEncodedWakePrompt(paths, client, sessionID, kind, encoded, context);
}
