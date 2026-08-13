#!/usr/bin/env node

// Internal session-log reader for fm-model-telemetry.sh's `usage` command.
// It returns aggregate token counts and active wall time from sessions whose
// recorded cwd and start time identify the exact task attempt. Cost remains
// absent because the harnesses derive displayed spend from local price catalogs.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const [harness, worktree, startedAt] = process.argv.slice(2);
const startedMs = Date.parse(startedAt);
const emptyUsage = { inputTokens: null, outputTokens: null, cost: null, currency: null };

function emit(inputTokens, outputTokens, wallSeconds) {
  const hasUsage = Number.isFinite(inputTokens) && Number.isFinite(outputTokens);
  process.stdout.write(`${JSON.stringify({
    usage: hasUsage
      ? { inputTokens, outputTokens, cost: null, currency: null }
      : emptyUsage,
    wallSeconds: Number.isFinite(wallSeconds) && wallSeconds >= 0 ? wallSeconds : null,
  })}\n`);
}

function regularJsonlFiles(root) {
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

function rawLines(file) {
  return fs.readFileSync(file, "utf8").split("\n");
}

function parseLine(line) {
  try { return JSON.parse(line); } catch { return null; }
}

function lastTimestampMs(lines, fallbackMs) {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const row = parseLine(lines[index]);
    const timestampMs = Date.parse(row?.timestamp);
    if (Number.isFinite(timestampMs)) return Math.max(fallbackMs, timestampMs);
  }
  return fallbackMs;
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
    const directory = path.join(
      root,
      String(day.getUTCFullYear()),
      String(day.getUTCMonth() + 1).padStart(2, "0"),
      String(day.getUTCDate()).padStart(2, "0"),
    );
    files.push(...regularJsonlFiles(directory));
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

function exactSession(timestamp, cwd) {
  return cwd === worktree && Number.isFinite(Date.parse(timestamp)) && Date.parse(timestamp) >= startedMs;
}

function codexUsage() {
  const root = process.env.FM_CODEX_SESSIONS_OVERRIDE
    || path.join(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"), "sessions");
  let input = 0;
  let output = 0;
  let matched = false;
  let wallSeconds = 0;
  let durationMatched = false;
  const sessions = new Set();
  for (const file of datedCodexFiles(root)) {
    const lines = rawLines(file);
    const meta = parseLine(lines[0]);
    if (!meta || !exactSession(meta.payload?.timestamp, meta.payload?.cwd)) continue;
    const sessionId = meta.payload?.id;
    if (typeof sessionId !== "string" || sessions.has(sessionId)) continue;
    const sessionStartMs = Date.parse(meta.payload.timestamp);
    wallSeconds += (lastTimestampMs(lines, sessionStartMs) - sessionStartMs) / 1000;
    durationMatched = true;
    sessions.add(sessionId);
    let totals = null;
    for (const line of lines) {
      if (!line.includes('"type":"token_count"')) continue;
      const row = parseLine(line);
      const candidate = row?.type === "event_msg" ? row.payload?.info?.total_token_usage : null;
      if (Number.isFinite(candidate?.input_tokens) && Number.isFinite(candidate?.output_tokens)) {
        totals = candidate;
      }
    }
    if (!totals) continue;
    input += totals.input_tokens;
    output += totals.output_tokens;
    matched = true;
  }
  return {
    inputTokens: matched ? input : null,
    outputTokens: matched ? output : null,
    wallSeconds: durationMatched ? wallSeconds : null,
  };
}

function claudeUsage() {
  const root = process.env.FM_CLAUDE_PROJECTS_OVERRIDE
    || path.join(os.homedir(), ".claude", "projects");
  let input = 0;
  let output = 0;
  let matched = false;
  const messages = new Set();
  const sessions = new Set();
  let wallSeconds = 0;
  let durationMatched = false;
  for (const file of regularJsonlFiles(claudeProjectRoot(root))) {
    const lines = rawLines(file);
    let identity = null;
    for (const line of lines) {
      const candidate = parseLine(line);
      if (candidate?.cwd && candidate?.timestamp) {
        identity = candidate;
        break;
      }
    }
    if (!identity || !exactSession(identity.timestamp, identity.cwd)) continue;
    const sessionId = identity.sessionId;
    if (typeof sessionId === "string" && !sessions.has(sessionId)) {
      const sessionStartMs = Date.parse(identity.timestamp);
      wallSeconds += (lastTimestampMs(lines, sessionStartMs) - sessionStartMs) / 1000;
      durationMatched = true;
      sessions.add(sessionId);
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
      input += direct + cacheCreate + cacheRead;
      output += usage.output_tokens;
      matched = true;
    }
  }
  return {
    inputTokens: matched ? input : null,
    outputTokens: matched ? output : null,
    wallSeconds: durationMatched ? wallSeconds : null,
  };
}

function piUsage() {
  const root = process.env.FM_PI_SESSIONS_OVERRIDE
    || path.join(os.homedir(), ".pi", "agent", "sessions");
  let input = 0;
  let output = 0;
  let matched = false;
  const sessions = new Set();
  let wallSeconds = 0;
  let durationMatched = false;
  for (const file of regularJsonlFiles(piProjectRoot(root))) {
    const lines = rawLines(file);
    const meta = parseLine(lines[0]);
    if (!meta || !exactSession(meta.timestamp, meta.cwd)
      || typeof meta.id !== "string" || sessions.has(meta.id)) continue;
    const sessionStartMs = Date.parse(meta.timestamp);
    wallSeconds += (lastTimestampMs(lines, sessionStartMs) - sessionStartMs) / 1000;
    durationMatched = true;
    sessions.add(meta.id);
    let sessionMatched = false;
    for (const line of lines) {
      if (!line.includes('"role":"assistant"')) continue;
      const row = parseLine(line);
      const usage = row?.type === "message" && row.message?.role === "assistant"
        ? row.message?.usage
        : null;
      const cacheRead = usage?.cacheRead ?? 0;
      const cacheWrite = usage?.cacheWrite ?? 0;
      if (!usage || ![usage.input, cacheRead, cacheWrite, usage.output].every(Number.isFinite)) continue;
      input += usage.input + cacheRead + cacheWrite;
      output += usage.output;
      sessionMatched = true;
    }
    if (sessionMatched) {
      matched = true;
    }
  }
  return {
    inputTokens: matched ? input : null,
    outputTokens: matched ? output : null,
    wallSeconds: durationMatched ? wallSeconds : null,
  };
}

async function opencodeUsage() {
  const database = process.env.FM_OPENCODE_DB_OVERRIDE
    || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "opencode", "opencode.db");
  if (!fs.existsSync(database) || !fs.lstatSync(database).isFile()) return {};
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(database, { readOnly: true });
  try {
    const row = db.prepare(`
      SELECT COUNT(*) AS sessions,
             COALESCE(SUM(tokens_input + tokens_cache_read + tokens_cache_write), 0) AS input_tokens,
             COALESCE(SUM(tokens_output), 0) AS output_tokens,
             COALESCE(SUM(CASE WHEN time_updated >= time_created THEN time_updated - time_created ELSE 0 END), 0) AS wall_ms
        FROM session
       WHERE directory = ? AND time_created >= ?
    `).get(worktree, startedMs);
    return row.sessions > 0
      ? {
          inputTokens: Number(row.input_tokens),
          outputTokens: Number(row.output_tokens),
          wallSeconds: Number(row.wall_ms) / 1000,
        }
      : {};
  } finally {
    db.close();
  }
}

if (!harness || !worktree || !Number.isFinite(startedMs) || !path.isAbsolute(worktree)) {
  process.stderr.write("invalid model-usage arguments\n");
  process.exit(2);
}

let observation = {};
try {
  if (harness === "codex") observation = codexUsage();
  else if (harness === "claude") observation = claudeUsage();
  else if (harness === "pi" || harness === "pi-signed") observation = piUsage();
  else if (harness === "opencode") observation = await opencodeUsage();
  // Grok and Kimi have no locally verified durable usage-log surface. Returning
  // absent data is safer than parsing their rendered TUI or guessing a path.
} catch {
  observation = {};
}

emit(observation.inputTokens, observation.outputTokens, observation.wallSeconds);
