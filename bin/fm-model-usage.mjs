#!/usr/bin/env node

// Internal session-log reader for fm-model-telemetry.sh's `usage` command.
// It attributes only one durable harness session to an attempt. A cwd/time
// match with multiple sessions is deliberately unmeasured rather than summed.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [harness, worktree, startedAt, expectedSessionId = ""] = process.argv.slice(2);
const startedMs = Date.parse(startedAt);
const emptyUsage = {
  inputTokens: null,
  outputTokens: null,
  cachedTokens: null,
  cost: null,
  currency: null,
};

// The four primitives below are exported for bin/fm-session-digest.mjs, the
// day-scan sibling reader, so no second parser of these harness formats exists.
export function regularJsonlFiles(root) {
  if (!root || !fs.existsSync(root) || !fs.lstatSync(root).isDirectory()) return [];
  const found = [];
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) pending.push(candidate);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) found.push(candidate);
    }
  }
  return found;
}

export function rawLines(file) {
  return fs.readFileSync(file, "utf8").split("\n");
}

export function parseLine(line) {
  try { return JSON.parse(line); } catch { return null; }
}

export function lastTimestampMs(lines, fallbackMs) {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const row = parseLine(lines[index]);
    const timestampMs = Date.parse(row?.timestamp);
    if (Number.isFinite(timestampMs)) return Math.max(fallbackMs, timestampMs);
  }
  return fallbackMs;
}

function evidence(file) {
  try {
    return {
      path: file,
      sha256: crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"),
    };
  } catch {
    return null;
  }
}

function datedCodexFiles(root) {
  if (process.env.FM_CODEX_SESSIONS_OVERRIDE) return regularJsonlFiles(root);
  const files = [];
  const firstDay = new Date(startedMs);
  firstDay.setUTCHours(0, 0, 0, 0);
  firstDay.setUTCDate(firstDay.getUTCDate() - 1);
  const lastDay = new Date();
  lastDay.setUTCHours(0, 0, 0, 0);
  lastDay.setUTCDate(lastDay.getUTCDate() + 1);
  for (const day = firstDay; day <= lastDay; day.setUTCDate(day.getUTCDate() + 1)) {
    files.push(...regularJsonlFiles(path.join(
      root,
      String(day.getUTCFullYear()),
      String(day.getUTCMonth() + 1).padStart(2, "0"),
      String(day.getUTCDate()).padStart(2, "0"),
    )));
  }
  return files;
}

function claudeProjectRoot(root) {
  if (process.env.FM_CLAUDE_PROJECTS_OVERRIDE) return root;
  return path.join(root, worktree.replace(/[^A-Za-z0-9-]/g, "-"));
}

function piProjectRoot(root) {
  if (process.env.FM_PI_SESSIONS_OVERRIDE) return root;
  return path.join(root, `--${worktree.replace(/^\/+/, "").replaceAll("/", "-")}--`);
}

function exactSession(timestamp, cwd, sessionId) {
  return cwd === worktree
    && Number.isFinite(Date.parse(timestamp))
    && Date.parse(timestamp) >= startedMs
    && (!expectedSessionId || sessionId === expectedSessionId);
}

function result(sessions, inputTokens, outputTokens, cachedTokens, assistantTurns = null, hasUsage = false) {
  if (sessions.length !== 1) {
    return {
      inputTokens: null,
      outputTokens: null,
      cachedTokens: null,
      wallMs: null,
      assistantTurns: null,
      sessionId: null,
      usageEvidenceRef: null,
      usageComplete: false,
      usageSource: sessions.length === 0 ? "session-not-found" : "session-ambiguous",
    };
  }
  const session = sessions[0];
  const complete = hasUsage
    && [inputTokens, outputTokens, cachedTokens].every(Number.isFinite)
    && session.usageEvidenceRef !== null;
  return {
    inputTokens: complete ? inputTokens : null,
    outputTokens: complete ? outputTokens : null,
    cachedTokens: complete ? cachedTokens : null,
    wallMs: session.wallMs,
    assistantTurns,
    sessionId: session.id,
    usageEvidenceRef: session.usageEvidenceRef,
    usageComplete: complete,
    usageSource: complete ? "recorded" : (hasUsage ? "unreadable" : "session-matched-no-tokens"),
  };
}

function codexUsage() {
  const root = process.env.FM_CODEX_SESSIONS_OVERRIDE
    || path.join(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"), "sessions");
  const sessions = [];
  const seen = new Set();
  let input = 0;
  let output = 0;
  let cached = 0;
  let hasUsage = false;
  for (const file of datedCodexFiles(root)) {
    const lines = rawLines(file);
    const meta = parseLine(lines[0]);
    const sessionId = meta?.payload?.id ?? meta?.payload?.session_id;
    if (typeof sessionId !== "string" || seen.has(sessionId) || !exactSession(meta?.payload?.timestamp, meta?.payload?.cwd, sessionId)) continue;
    seen.add(sessionId);
    sessions.push({
      id: sessionId,
      wallMs: lastTimestampMs(lines, Date.parse(meta.payload.timestamp)) - Date.parse(meta.payload.timestamp),
      usageEvidenceRef: evidence(file),
    });
    let totals = null;
    for (const line of lines) {
      if (!line.includes('"type":"token_count"')) continue;
      const row = parseLine(line);
      const candidate = row?.type === "event_msg" ? row.payload?.info?.total_token_usage : null;
      if (Number.isFinite(candidate?.input_tokens) && Number.isFinite(candidate?.output_tokens)) totals = candidate;
    }
    if (!totals) continue;
    input += totals.input_tokens;
    output += totals.output_tokens;
    cached += (totals.cached_input_tokens ?? 0) + (totals.cache_write_input_tokens ?? 0);
    hasUsage = true;
  }
  return result(sessions, input, output, cached, null, hasUsage);
}

function claudeUsage() {
  const root = process.env.FM_CLAUDE_PROJECTS_OVERRIDE
    || path.join(os.homedir(), ".claude", "projects");
  const sessions = [];
  const messages = new Set();
  const sessionKeys = new Set();
  let input = 0;
  let output = 0;
  let cached = 0;
  let hasUsage = false;
  for (const file of regularJsonlFiles(claudeProjectRoot(root))) {
    const lines = rawLines(file);
    const identity = lines.map(parseLine).find((row) => row?.cwd && row?.timestamp);
    const sessionId = identity?.sessionId;
    if (typeof sessionId !== "string" || !exactSession(identity.timestamp, identity.cwd, sessionId)) continue;
    if (!sessionKeys.has(sessionId)) {
      sessionKeys.add(sessionId);
      const sessionStartMs = Date.parse(identity.timestamp);
      sessions.push({
        id: sessionId,
        wallMs: lastTimestampMs(lines, sessionStartMs) - sessionStartMs,
        usageEvidenceRef: evidence(file),
      });
    }
    for (const line of lines) {
      if (!line.includes('"type":"assistant"')) continue;
      const row = parseLine(line);
      const usage = row?.type === "assistant" ? row.message?.usage : null;
      const messageId = row?.message?.id;
      if (!usage || typeof messageId !== "string" || messages.has(messageId)) continue;
      const direct = usage.input_tokens;
      const cacheCreate = usage.cache_creation_input_tokens ?? 0;
      const cacheRead = usage.cache_read_input_tokens ?? 0;
      if (![direct, cacheCreate, cacheRead, usage.output_tokens].every(Number.isFinite)) continue;
      messages.add(messageId);
      input += direct;
      cached += cacheCreate + cacheRead;
      output += usage.output_tokens;
      hasUsage = true;
    }
  }
  return result(sessions, input, output, cached, null, hasUsage);
}

function piUsage() {
  const root = process.env.FM_PI_SESSIONS_OVERRIDE
    || path.join(os.homedir(), ".pi", "agent", "sessions");
  const sessions = [];
  const seen = new Set();
  let input = 0;
  let output = 0;
  let cached = 0;
  let assistantTurns = 0;
  let hasUsage = false;
  for (const file of regularJsonlFiles(piProjectRoot(root))) {
    const lines = rawLines(file);
    const meta = parseLine(lines[0]);
    const sessionId = meta?.id;
    if (typeof sessionId !== "string" || seen.has(sessionId) || !exactSession(meta?.timestamp, meta?.cwd, sessionId)) continue;
    seen.add(sessionId);
    const sessionStartMs = Date.parse(meta.timestamp);
    sessions.push({
      id: sessionId,
      wallMs: lastTimestampMs(lines, sessionStartMs) - sessionStartMs,
      usageEvidenceRef: evidence(file),
    });
    for (const line of lines) {
      if (!line.includes('"assistant"')) continue;
      const row = parseLine(line);
      const isAssistant = row?.type === "message" && row.message?.role === "assistant";
      if (!isAssistant) continue;
      assistantTurns += 1;
      const usage = row.message?.usage;
      const cacheRead = usage?.cacheRead ?? 0;
      const cacheWrite = usage?.cacheWrite ?? 0;
      if (!usage || ![usage.input, cacheRead, cacheWrite, usage.output].every(Number.isFinite)) continue;
      input += usage.input;
      cached += cacheRead + cacheWrite;
      output += usage.output;
      hasUsage = true;
    }
  }
  return result(sessions, input, output, cached, sessions.length === 1 ? assistantTurns : null, hasUsage);
}

async function opencodeUsage() {
  const database = process.env.FM_OPENCODE_DB_OVERRIDE
    || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "opencode", "opencode.db");
  if (!fs.existsSync(database) || !fs.lstatSync(database).isFile()) return {};
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(database, { readOnly: true });
  try {
    const rows = db.prepare(`
      SELECT id,
             tokens_input AS input_tokens,
             tokens_cache_read + tokens_cache_write AS cached_tokens,
             tokens_output AS output_tokens,
             CASE WHEN time_updated >= time_created THEN time_updated - time_created ELSE 0 END AS wall_ms
        FROM session
       WHERE directory = ? AND time_created >= ?
    `).all(worktree, startedMs);
    const matched = rows.filter((row) => typeof row.id === "string" && (!expectedSessionId || row.id === expectedSessionId));
    const sessions = matched
      .map((row) => ({ id: row.id, wallMs: Number(row.wall_ms), usageEvidenceRef: evidence(database) }));
    return result(
      sessions,
      matched.reduce((total, row) => total + Number(row.input_tokens), 0),
      matched.reduce((total, row) => total + Number(row.output_tokens), 0),
      matched.reduce((total, row) => total + Number(row.cached_tokens), 0),
      null,
      matched.length === 1,
    );
  } finally {
    db.close();
  }
}

function emit(observation, harnessSource) {
  const source = observation.usageSource || harnessSource;
  const complete = observation.usageComplete === true;
  process.stdout.write(`${JSON.stringify({
    usage: complete
      ? {
          inputTokens: observation.inputTokens,
          outputTokens: observation.outputTokens,
          cachedTokens: observation.cachedTokens,
          cost: null,
          currency: null,
        }
      : emptyUsage,
    wallMs: Number.isFinite(observation.wallMs) && observation.wallMs >= 0 ? observation.wallMs : null,
    wallSeconds: Number.isFinite(observation.wallMs) && observation.wallMs >= 0 ? observation.wallMs / 1000 : null,
    usageSource: source,
    assistantTurns: observation.assistantTurns ?? null,
    sessionId: observation.sessionId ?? null,
    usageEvidenceRef: observation.usageEvidenceRef ?? null,
    usageComplete: complete,
    missingReason: complete ? null : source,
  })}\n`);
}

// Importing this module for its exported primitives must not run the
// single-attempt read, so the entry point fires only for the invoked script.
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  if (!harness || !worktree || !Number.isFinite(startedMs) || !path.isAbsolute(worktree)) {
    process.stderr.write("invalid model-usage arguments\n");
    process.exit(2);
  }

  let observation = {};
  let harnessSource = "session-not-found";
  try {
    if (harness === "codex") observation = codexUsage();
    else if (harness === "claude") observation = claudeUsage();
    else if (harness === "pi" || harness === "pi-signed") observation = piUsage();
    else if (harness === "opencode") observation = await opencodeUsage();
    else harnessSource = "no-verified-source";
  } catch {
    harnessSource = ["grok", "kimi", "cursor-agent"].includes(harness) ? "no-verified-source" : "unreadable";
  }
  emit(observation, harnessSource);
}
