#!/usr/bin/env node
// fm-quota.mjs - read Codex native account quota and TraeX model load.
//
// Usage:
//   bin/fm-quota.mjs [--json] [--provider codex|traex]... [--model NAME]...
//
// Codex is queried through one task-owned `codex app-server --stdio` child.
// The child receives only initialize, initialized, and account/rateLimits/read,
// then its stdin is closed and the command waits for normal exit.
// TraeX is queried through `traex models --json`.
// Both children inherit the caller's environment so configured proxy routing is
// preserved. FM_QUOTA_TIMEOUT_MS bounds each provider read (default 10000).

import { spawn } from "node:child_process";
import readline from "node:readline";

const DEFAULT_TIMEOUT_MS = 10_000;
const NORMAL_EXIT_GRACE_MS = 1_000;
const TERMINATION_GRACE_MS = 400;
const MAX_CAPTURE_BYTES = 64 * 1024;
const PROVIDER_ORDER = ["codex", "traex"];
const activeChildren = new Set();
let interruptionCleanup;

function usage(stream = process.stdout) {
  stream.write(`Usage: fm-quota.mjs [--json] [--provider codex|traex]... [--model NAME]...

Read live Codex account quota and TraeX model load without starting a prompt.
With no provider selection, both providers are queried.
Use --model to select TraeX models by name, config name, or backend model.
`);
}

function dieUsage(message) {
  process.stderr.write(`fm-quota: ${message}\n`);
  usage(process.stderr);
  process.exit(2);
}

function parseArgs(argv) {
  const options = { json: false, providers: [], models: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "-h" || argument === "--help") return { help: true };
    if (argument === "--json") {
      options.json = true;
      continue;
    }
    if (argument === "--provider" || argument === "--model") {
      const value = argv[index += 1];
      if (!value) dieUsage(`${argument} requires a value`);
      if (argument === "--provider") {
        if (!PROVIDER_ORDER.includes(value)) dieUsage(`unsupported provider ${value}`);
        if (!options.providers.includes(value)) options.providers.push(value);
      } else {
        if (!options.models.includes(value)) options.models.push(value);
      }
      continue;
    }
    dieUsage(`unknown argument ${argument}`);
  }
  if (options.providers.length === 0) options.providers = [...PROVIDER_ORDER];
  if (options.models.length > 0 && !options.providers.includes("traex")) {
    dieUsage("--model requires the traex provider");
  }
  return options;
}

function timeoutMs() {
  const raw = process.env.FM_QUOTA_TIMEOUT_MS || String(DEFAULT_TIMEOUT_MS);
  if (!/^[0-9]+$/.test(raw)) dieUsage("FM_QUOTA_TIMEOUT_MS must be a whole number from 100 through 60000");
  const value = Number(raw);
  if (value < 100 || value > 60_000) dieUsage("FM_QUOTA_TIMEOUT_MS must be a whole number from 100 through 60000");
  return value;
}

function appendBounded(current, chunk) {
  if (Buffer.byteLength(current) >= MAX_CAPTURE_BYTES) return current;
  const remaining = MAX_CAPTURE_BYTES - Buffer.byteLength(current);
  return current + chunk.toString("utf8", 0, remaining);
}

function taskChild(command, args) {
  const child = spawn(command, args, {
    detached: process.platform !== "win32",
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  activeChildren.add(child);
  child.once("close", () => { activeChildren.delete(child); });
  child.stdin.on("error", () => {});
  return child;
}

function signalTaskChild(child, signal) {
  if (!child.pid) return;
  try {
    if (process.platform === "win32") {
      if (child.exitCode === null && child.signalCode === null) child.kill(signal);
    }
    else process.kill(-child.pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}

function waitForExit(child) {
  if (!activeChildren.has(child)) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  }
  return new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal })));
}

async function waitWithTimeout(promise, milliseconds) {
  const timedOut = Symbol("timed-out");
  let timer;
  const result = await Promise.race([
    promise,
    new Promise((resolve) => { timer = setTimeout(() => resolve(timedOut), milliseconds); }),
  ]);
  clearTimeout(timer);
  return result === timedOut;
}

async function stopTaskChild(child) {
  if (!activeChildren.has(child)) {
    return { forced: false, code: child.exitCode, signal: child.signalCode };
  }
  const exit = waitForExit(child);
  try { child.stdin.end(); } catch {}
  const exitTimedOut = await waitWithTimeout(exit, NORMAL_EXIT_GRACE_MS);
  if (!exitTimedOut) return { forced: false, ...(await exit) };
  signalTaskChild(child, "SIGTERM");
  const terminationTimedOut = await waitWithTimeout(exit, TERMINATION_GRACE_MS);
  if (terminationTimedOut) {
    signalTaskChild(child, "SIGKILL");
    const killTimedOut = await waitWithTimeout(exit, TERMINATION_GRACE_MS);
    if (killTimedOut) return { forced: true, code: child.exitCode, signal: child.signalCode };
  }
  return { forced: true, ...(await exit) };
}

async function cleanupAfterInterruption(signal, exitCode) {
  if (interruptionCleanup) return interruptionCleanup;
  interruptionCleanup = (async () => {
    const pending = [...activeChildren].map((child) => ({ child, exit: waitForExit(child) }));
    for (const { child } of pending) signalTaskChild(child, signal);
    const exited = await waitWithTimeout(Promise.all(pending.map(({ exit }) => exit)), TERMINATION_GRACE_MS);
    if (!exited) {
      for (const { child } of pending) signalTaskChild(child, "SIGKILL");
      await waitWithTimeout(Promise.all(pending.map(({ exit }) => exit)), TERMINATION_GRACE_MS);
    }
    process.exit(exitCode);
  })();
  return interruptionCleanup;
}

process.once("SIGINT", () => { void cleanupAfterInterruption("SIGINT", 130); });
process.once("SIGTERM", () => { void cleanupAfterInterruption("SIGTERM", 143); });
process.once("SIGHUP", () => { void cleanupAfterInterruption("SIGHUP", 129); });

function diagnosticText(value) {
  let raw;
  if (typeof value === "string") raw = value;
  else if (value && typeof value === "object" && typeof value.message === "string") {
    raw = `${value.code === undefined ? "" : `${value.code}: `}${value.message}`;
  } else {
    try { raw = JSON.stringify(value); } catch { raw = ""; }
  }
  const sanitized = String(raw || "").replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  return sanitized ? sanitized.slice(0, 500) : null;
}

function finalStderrLine(stderr) {
  const line = stderr.trim().split("\n").filter(Boolean).at(-1);
  return diagnosticText(line);
}

function providerUnavailable(provider, message, attemptedAt) {
  return { provider, status: "unavailable", attempted_at: attemptedAt, error: message };
}

function childFailure(provider, command, error, attemptedAt) {
  if (error?.code === "ENOENT") return providerUnavailable(provider, `${command} is not installed or not on PATH`, attemptedAt);
  return providerUnavailable(provider, error?.message || `${command} failed`, attemptedAt);
}

async function readCodex(timeout) {
  const attemptedAt = new Date().toISOString();
  let child;
  try {
    child = taskChild("codex", ["app-server", "--stdio"]);
  } catch (error) {
    return childFailure("codex", "codex", error, attemptedAt);
  }

  let stderr = "";
  let settled = false;
  let childClosed = false;
  let initialized = false;
  let result;
  let failure;
  child.stderr.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });
  child.once("close", () => { childClosed = true; });
  child.once("error", (error) => { failure = error; });
  const lines = readline.createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    if (settled || !line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      failure = new Error("codex app-server returned malformed JSON");
      settled = true;
      return;
    }
    if (message.id === "fm-quota-initialize") {
      if (message.error) {
        const detail = diagnosticText(message.error);
        failure = new Error(`Codex app-server rejected initialization${detail ? `: ${detail}` : ""}`);
        settled = true;
        return;
      }
      initialized = true;
      child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
      child.stdin.write(`${JSON.stringify({ id: "fm-quota-read", method: "account/rateLimits/read", params: { excludeResetCreditDetails: true } })}\n`);
      return;
    }
    if (message.id === "fm-quota-read") {
      if (message.error) {
        const detail = diagnosticText(message.error);
        failure = new Error(`Codex account quota read was rejected${detail ? `: ${detail}` : ""}`);
      }
      else result = message.result;
      settled = true;
      child.stdin.end();
    }
  });

  child.stdin.write(`${JSON.stringify({
    id: "fm-quota-initialize",
    method: "initialize",
    params: { clientInfo: { name: "firstmate-quota", version: "1.0.0" }, capabilities: {} },
  })}\n`);

  const timedOut = await waitWithTimeout(
    new Promise((resolve) => {
      const poll = () => {
        if (settled || failure || childClosed) resolve();
        else setTimeout(poll, 10);
      };
      poll();
    }),
    timeout,
  );
  if (timedOut && !settled) failure = new Error(`Codex quota read timed out after ${timeout}ms`);

  const cleanup = await stopTaskChild(child);
  const exit = child.exitCode;
  lines.close();
  if (!failure && result && cleanup.forced) failure = new Error("Codex app-server did not exit after its stdin was closed");
  if (!failure && !result) {
    const detail = finalStderrLine(stderr);
    failure = new Error(initialized
      ? `Codex quota response was unavailable${detail ? `: ${detail}` : ""}`
      : `Codex app-server exited before initialization${exit === null ? "" : ` (exit ${exit})`}${detail ? `: ${detail}` : ""}`);
  }
  if (failure) return childFailure("codex", "codex", failure, attemptedAt);
  if (!result || typeof result !== "object" || !result.rateLimits || typeof result.rateLimits !== "object") {
    return providerUnavailable("codex", "Codex quota response omitted rateLimits", attemptedAt);
  }

  const byId = result.rateLimitsByLimitId;
  const snapshots = byId && typeof byId === "object" && !Array.isArray(byId) && Object.keys(byId).length > 0
    ? Object.entries(byId)
    : [[result.rateLimits.limitId || "default", result.rateLimits]];
  return {
    provider: "codex",
    status: "ok",
    fetched_at: new Date().toISOString(),
    ordinary_usage_allowed: result.ordinaryUsageAllowed ?? null,
    rate_limits: snapshots.map(([identity, snapshot]) => normalizeRateLimit(identity, snapshot)),
    credits: normalizeCredits(result.rateLimits.credits),
    reset_credits_available: result.rateLimitResetCredits?.availableCount ?? null,
  };
}

function canonicalInstant(unixSeconds) {
  if (!Number.isInteger(unixSeconds)) return null;
  const instant = new Date(unixSeconds * 1000);
  return Number.isNaN(instant.getTime()) ? null : instant.toISOString();
}

function normalizeWindow(window) {
  if (!window || typeof window !== "object") return null;
  return {
    used_percent: Number.isFinite(window.usedPercent) ? window.usedPercent : null,
    window_duration_minutes: Number.isInteger(window.windowDurationMins) ? window.windowDurationMins : null,
    resets_at: canonicalInstant(window.resetsAt),
    resets_at_unix: Number.isInteger(window.resetsAt) ? window.resetsAt : null,
  };
}

function normalizeCredits(credits) {
  if (!credits || typeof credits !== "object") return null;
  return {
    has_credits: typeof credits.hasCredits === "boolean" ? credits.hasCredits : null,
    unlimited: typeof credits.unlimited === "boolean" ? credits.unlimited : null,
    balance: typeof credits.balance === "string" ? credits.balance : null,
  };
}

function normalizeRateLimit(identity, snapshot) {
  return {
    id: snapshot?.limitId ?? identity,
    name: snapshot?.limitName ?? null,
    plan_type: snapshot?.planType ?? null,
    normal_model_slug: snapshot?.normalModelSlug ?? null,
    primary: normalizeWindow(snapshot?.primary),
    secondary: normalizeWindow(snapshot?.secondary),
    reached_type: snapshot?.rateLimitReachedType ?? null,
    spend_control_reached: typeof snapshot?.spendControlReached === "boolean" ? snapshot.spendControlReached : null,
  };
}

async function readCommandJson(command, args, timeout) {
  const child = taskChild(command, args);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout = appendBounded(stdout, chunk); });
  child.stderr.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });
  let spawnError;
  child.once("error", (error) => { spawnError = error; });
  const timedOut = await waitWithTimeout(waitForExit(child), timeout);
  if (timedOut) {
    await stopTaskChild(child);
    throw new Error(`${command} timed out after ${timeout}ms`);
  }
  if (spawnError) throw spawnError;
  if (child.exitCode !== 0) {
    const detail = stderr.trim().split("\n").filter(Boolean).at(-1);
    throw new Error(`${command} exited ${child.exitCode}${detail ? `: ${detail}` : ""}`);
  }
  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(`${command} returned malformed JSON`);
  }
}

function modelIdentities(model) {
  return [model?.name, model?.config_name, model?.backend_model].filter((value) => typeof value === "string");
}

async function readTraex(timeout, selectedModels) {
  const attemptedAt = new Date().toISOString();
  let raw;
  try {
    raw = await readCommandJson("traex", ["models", "--json"], timeout);
  } catch (error) {
    return childFailure("traex", "traex", error, attemptedAt);
  }
  if (!Array.isArray(raw)) return providerUnavailable("traex", "TraeX model response was not an array", attemptedAt);

  const wanted = new Set(selectedModels);
  const matched = new Set();
  const models = [];
  for (const model of raw) {
    const identities = modelIdentities(model);
    if (wanted.size > 0 && !identities.some((identity) => wanted.has(identity))) continue;
    for (const identity of identities) if (wanted.has(identity)) matched.add(identity);
    const load = model?._meta?.trae?.load?.percent;
    models.push({
      name: typeof model?.name === "string" ? model.name : null,
      config_name: typeof model?.config_name === "string" ? model.config_name : null,
      backend_model: typeof model?.backend_model === "string" ? model.backend_model : null,
      provider: typeof model?.provider === "string" ? model.provider : null,
      load_percent: Number.isFinite(load) ? load : null,
      load_available: Number.isFinite(load),
    });
  }
  const unavailableModels = selectedModels.filter((identity) => !matched.has(identity));
  if (models.length === 0) {
    const suffix = unavailableModels.length > 0 ? `: ${unavailableModels.join(", ")}` : "";
    return providerUnavailable("traex", `requested TraeX models were unavailable${suffix}`, attemptedAt);
  }
  return {
    provider: "traex",
    status: models.some((model) => !model.load_available) || unavailableModels.length > 0 ? "partial" : "ok",
    fetched_at: new Date().toISOString(),
    models,
    unavailable_models: unavailableModels,
  };
}

function utc8(instant) {
  if (!instant) return "unavailable";
  const date = new Date(instant);
  if (Number.isNaN(date.getTime())) return "unavailable";
  return `${new Date(date.getTime() + 8 * 60 * 60 * 1000).toISOString().slice(0, 19).replace("T", " ")} UTC+8`;
}

function windowText(label, window) {
  if (!window) return `    ${label}: unavailable`;
  const used = window.used_percent === null ? "usage unavailable" : `${window.used_percent}% used`;
  const duration = window.window_duration_minutes === null ? "window unavailable" : `${window.window_duration_minutes} minute window`;
  return `    ${label}: ${used}; ${duration}; resets ${utc8(window.resets_at)}`;
}

function renderHuman(report) {
  const lines = [`Checked: ${utc8(report.checked_at)}`];
  const codex = report.providers.codex;
  if (codex) {
    lines.push("", "Codex quota:");
    if (codex.status === "unavailable") lines.push(`  unavailable: ${codex.error}`);
    else {
      lines.push(`  ordinary usage allowed: ${codex.ordinary_usage_allowed === null ? "unavailable" : codex.ordinary_usage_allowed}`);
      for (const limit of codex.rate_limits) {
        lines.push(`  ${limit.id || "default"}${limit.plan_type ? ` (${limit.plan_type})` : ""}:`);
        lines.push(windowText("primary", limit.primary), windowText("secondary", limit.secondary));
      }
      if (codex.credits) {
        lines.push(`  credits: ${codex.credits.unlimited ? "unlimited" : codex.credits.balance ?? "balance unavailable"}`);
      }
      lines.push(`  reset credits available: ${codex.reset_credits_available ?? "unavailable"}`);
    }
  }
  const traex = report.providers.traex;
  if (traex) {
    lines.push("", "TraeX model load:");
    if (traex.status === "unavailable") lines.push(`  unavailable: ${traex.error}`);
    else {
      for (const model of traex.models) {
        lines.push(`  ${model.name ?? model.config_name ?? model.backend_model ?? "unknown model"}: ${model.load_available ? `${model.load_percent}%` : "unavailable"}`);
      }
      for (const identity of traex.unavailable_models) lines.push(`  ${identity}: unavailable`);
    }
  }
  process.stdout.write(`${lines.join("\n")}\n`);
}

const options = parseArgs(process.argv.slice(2));
if (options.help) {
  usage();
  process.exit(0);
}
const timeout = timeoutMs();
const providerResults = {};
for (const provider of PROVIDER_ORDER) {
  if (!options.providers.includes(provider)) continue;
  providerResults[provider] = provider === "codex"
    ? await readCodex(timeout)
    : await readTraex(timeout, options.models);
}
const results = Object.values(providerResults);
const hardFailures = results.filter((provider) => provider.status === "unavailable");
const report = {
  schema: "fm-quota-v1",
  status: hardFailures.length === results.length ? "unavailable" : results.some((provider) => provider.status !== "ok") ? "partial" : "ok",
  checked_at: new Date().toISOString(),
  providers: providerResults,
};
if (options.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
else renderHuman(report);
if (hardFailures.length > 0) process.exitCode = 1;
