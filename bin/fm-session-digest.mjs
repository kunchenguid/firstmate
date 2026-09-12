#!/usr/bin/env node

// One-local-day session digest reader for bin/fm-session-digest.sh.
//
// It reuses the discovery and line primitives exported by bin/fm-model-usage.mjs
// so no second parser of the Claude, Pi, or Codex session format exists, and it
// writes $FM_IMPROVEMENTS_DIR/<YYYY-MM-DD>.md plus one "WROTE <path>" line on stdout.
// The wrapper owns argument help, the elapsed-time line, the 0600 mode, and
// data/improvements/README.md.
//
// Privacy contract: this module records counts, identifiers, and at most the
// first CORRECTION_QUOTE_CHARS characters of a captain correction. It never
// writes assistant text, tool output, or file contents.
//
// Usage:
//   fm-session-digest.mjs [--date YYYY-MM-DD | --today]
//
// The output directory is FM_IMPROVEMENTS_DIR, defaulting to
// <repo>/data/improvements.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { regularJsonlFiles, rawLines, parseLine, lastTimestampMs } from "./fm-model-usage.mjs";

// --- correction markers -----------------------------------------------------
//
// One owner for what counts as a captain redirect. A message counts once, and
// only its head is matched, because a redirect *starts* a message while long
// briefs and pasted plans merely contain these words somewhere.
// Add a pattern here to extend the table; nothing else changes.
const CORRECTION_PATTERNS = [
  /\bno,/i, /\bnot that\b/i, /\bwrong\b/i, /\bactually\b/i, /\binstead\b/i,
  /\bstop\b/i, /\bagain\b/i,
  // PT-BR equivalents
  /\bn[ãa]o,/i, /\bn[ãa]o [ée] isso\b/i, /\berrad[oa]\b/i, /\bna verdade\b/i,
  /\bem vez de\b/i, /\bao inv[ée]s\b/i, /\bpare\b/i, /\bde novo\b/i,
  /\bnovamente\b/i, /\brefa[çc]a\b/i,
];
const CORRECTION_HEAD_CHARS = 200;
const CORRECTION_QUOTE_CHARS = 120;
// Injected harness traffic that is never a captain message: firstmate operation
// blocks, Claude caveat/command wrappers, and skill bodies.
const INJECTED_HEAD = ["FIRSTMATE_OP:", "<local-command", "<command-name>", "<command-message",
  "Caveat:", "Base directory for this skill"];

// Candidate thresholds. Each one names a likely owner so the weekly ritual gets
// a routed proposal instead of a bare number.
const CANDIDATE_RULES = [
  { key: "retries", min: 3, owner: "bin script" },
  { key: "corrections", min: 2, owner: "brief" },
  { key: "errors", min: 5, owner: "skill" },
];
const FRICTION_TOP = 5;
const CANDIDATE_MAX = 3;
const HEAD_BYTES = 512 * 1024;
// A Firstmate worker names its own status file in its launch brief, which is the
// durable in-log path to its task id (FM_TASK_ID never reaches the session log).
const TASK_STATUS_PATTERN = /state\/([A-Za-z0-9._-]+)\.status/;
const TASK_PATH_PATTERN = /(?:^|\/)(?:private\/)?tmp\/fm-(?:2ndmate|firstmate)-[A-Za-z0-9._-]+?-[0-9a-f]{6,}-(.+?)(?:\/|$)/;

// --- arguments --------------------------------------------------------------

const argv = process.argv.slice(2);
const repoRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
let outDir = process.env.FM_IMPROVEMENTS_DIR
  || path.join(repoRoot, "data", "improvements");
let daySpec = "yesterday";
for (let index = 0; index < argv.length; index += 1) {
  const flag = argv[index];
  if (flag === "--date") { daySpec = argv[index += 1]; }
  else if (flag === "--today") { daySpec = "today"; }
  else {
    process.stderr.write("invalid session-digest arguments\n");
    process.exit(2);
  }
}
if (!outDir) {
  process.stderr.write("invalid session-digest arguments\n");
  process.exit(2);
}

function localDay(spec) {
  const now = new Date();
  if (spec === "today") return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  if (spec === "yesterday") return new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  const parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(spec);
  if (!parts) return null;
  const day = new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]));
  // Reject a calendar day that Date silently rolled over, e.g. 2026-02-30.
  return day.getDate() === Number(parts[3]) ? day : null;
}

const day = localDay(daySpec);
if (!day) {
  process.stderr.write(`invalid date: ${daySpec}\n`);
  process.exit(2);
}
const dayStartMs = day.getTime();
const dayEndMs = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime();
const dayName = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
const inDay = (ms) => Number.isFinite(ms) && ms >= dayStartMs && ms < dayEndMs;

// --- discovery --------------------------------------------------------------

function harnessRoot(name) {
  if (name === "claude") {
    return process.env.FM_CLAUDE_PROJECTS_OVERRIDE || path.join(os.homedir(), ".claude", "projects");
  }
  if (name === "pi") {
    return process.env.FM_PI_SESSIONS_OVERRIDE || path.join(os.homedir(), ".pi", "agent", "sessions");
  }
  return process.env.FM_CODEX_SESSIONS_OVERRIDE
    || path.join(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"), "sessions");
}

function existingFiles(files) {
  return files.filter((file) => {
    try { return fs.statSync(file).mtimeMs >= dayStartMs; } catch { return false; }
  });
}

// Codex partitions by UTC day, so a local day can span two of its directories.
function codexFiles() {
  const root = harnessRoot("codex");
  if (process.env.FM_CODEX_SESSIONS_OVERRIDE || !fs.existsSync(root)) return existingFiles(regularJsonlFiles(root));
  const files = [];
  for (let cursor = new Date(dayStartMs); cursor.getTime() < dayEndMs; cursor = new Date(cursor.getTime() + 3600000)) {
    const directory = path.join(root, String(cursor.getUTCFullYear()),
      String(cursor.getUTCMonth() + 1).padStart(2, "0"), String(cursor.getUTCDate()).padStart(2, "0"));
    if (fs.existsSync(directory)) files.push(...regularJsonlFiles(directory));
  }
  return existingFiles([...new Set(files)]);
}

function dayFiles(harness) {
  const root = harnessRoot(harness);
  if (harness === "codex") return codexFiles();
  if (!fs.existsSync(root)) return [];
  return existingFiles(regularJsonlFiles(root));
}

// Read only the head of a candidate file to find its session identity, so a day
// scan never parses gigabytes of sessions that started on an earlier day.
function headRows(file) {
  let fd = null;
  try {
    fd = fs.openSync(file, "r");
    const buffer = Buffer.alloc(HEAD_BYTES);
    const read = fs.readSync(fd, buffer, 0, HEAD_BYTES, 0);
    const lines = buffer.toString("utf8", 0, read).split("\n");
    if (read === HEAD_BYTES) lines.pop();
    const rows = [];
    for (const line of lines) {
      const row = parseLine(line);
      if (row) rows.push(row);
    }
    return rows;
  } catch {
    return [];
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }
}

// --- session accumulator ----------------------------------------------------

function newSession(harness, sessionId, cwd, startedMs) {
  return {
    harness,
    session: String(sessionId ?? "-").slice(-8),
    cwd: cwd || "",
    startedMs,
    model: null,
    effort: null,
    input: 0,
    output: 0,
    cache: 0,
    toolCalls: 0,
    toolErrors: 0,
    toolKeys: new Map(),
    userTurns: 0,
    task: "",
    corrections: [],
  };
}

function noteTool(session, tool, argsKey) {
  session.toolCalls += 1;
  const key = `${tool || "tool"}\u0000${String(argsKey ?? "").slice(0, 400)}`;
  session.toolKeys.set(key, (session.toolKeys.get(key) || 0) + 1);
}

function retryStats(session) {
  let retries = 0;
  let topTool = "-";
  let topCount = 1;
  for (const [key, count] of session.toolKeys) {
    if (count < 2) continue;
    retries += count - 1;
    if (count > topCount) { topCount = count; topTool = key.split("\u0000")[0]; }
  }
  return { retries, topTool };
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block && typeof block.text === "string"
      && ["text", "input_text", "output_text"].includes(block.type))
    .map((block) => block.text)
    .join("\n");
}

function correctionQuote(text) {
  const trimmed = text.trimStart();
  if (!trimmed) return null;
  const head = trimmed.slice(0, CORRECTION_HEAD_CHARS);
  if (INJECTED_HEAD.some((marker) => head.includes(marker))) return null;
  if (!CORRECTION_PATTERNS.some((pattern) => pattern.test(head))) return null;
  return trimmed.slice(0, CORRECTION_QUOTE_CHARS).replace(/\s+/g, " ");
}

function noteUserText(session, text) {
  session.userTurns += 1;
  if (!session.task && session.userTurns <= 3) {
    const match = text.slice(0, 40000).match(TASK_STATUS_PATTERN);
    if (match) session.task = match[1];
  }
  const quote = correctionQuote(text);
  if (quote) session.corrections.push(quote);
}

function placeLabel(cwd) {
  if (!cwd) return "-";
  const treehouse = /\/\.treehouse\/([^/]+)\/([^/]+)/.exec(cwd);
  if (treehouse) return `wt:${treehouse[1]}-${treehouse[2]}`;
  const scratch = /(?:^|\/)(?:private\/)?tmp\/(fm-[^/]+)/.exec(cwd);
  if (scratch) return `wt:${scratch[1].slice(0, 40)}`;
  return `home:${path.basename(cwd.replace(/\/+$/, "")) || cwd}`;
}

function taskLabel(session) {
  if (session.task) return session.task;
  const fromPath = TASK_PATH_PATTERN.exec(session.cwd);
  return fromPath ? fromPath[1] : "-";
}

// --- per-harness extraction -------------------------------------------------

function piSessions() {
  const sessions = [];
  for (const file of dayFiles("pi")) {
    const meta = headRows(file).find((row) => row?.type === "session");
    if (!meta || !inDay(Date.parse(meta.timestamp))) continue;
    const lines = rawLines(file);
    const startedMs = Date.parse(meta.timestamp);
    const session = newSession("pi", meta.id, meta.cwd, startedMs);
    const endedMs = lastTimestampMs(lines, startedMs);
    for (const line of lines) {
      const row = parseLine(line);
      if (!row) continue;
      if (row.type === "model_change" && row.modelId) session.model = row.modelId;
      else if (row.type === "thinking_level_change" && row.thinkingLevel) session.effort = row.thinkingLevel;
      else if (row.type === "message" && row.message) {
        const message = row.message;
        if (message.role === "assistant") {
          if (message.model) session.model = message.model;
          const usage = message.usage;
          if (usage) {
            session.input += Number(usage.input) || 0;
            session.output += Number(usage.output) || 0;
            session.cache += (Number(usage.cacheRead) || 0) + (Number(usage.cacheWrite) || 0);
          }
          for (const block of Array.isArray(message.content) ? message.content : []) {
            if (block?.type === "toolCall") noteTool(session, block.name, JSON.stringify(block.arguments ?? ""));
          }
        } else if (message.role === "toolResult") {
          if (message.isError) session.toolErrors += 1;
        } else if (message.role === "user") {
          noteUserText(session, textOf(message.content));
        }
      }
    }
    session.wallSeconds = Math.max(0, Math.round((endedMs - startedMs) / 1000));
    sessions.push(session);
  }
  return sessions;
}

function claudeSessions() {
  const sessions = [];
  for (const file of dayFiles("claude")) {
    const identity = headRows(file).find((row) => row?.cwd && row?.timestamp);
    if (!identity || !inDay(Date.parse(identity.timestamp))) continue;
    const lines = rawLines(file);
    const startedMs = Date.parse(identity.timestamp);
    const session = newSession("claude", identity.sessionId, identity.cwd, startedMs);
    const endedMs = lastTimestampMs(lines, startedMs);
    const countedMessages = new Set();
    for (const line of lines) {
      const row = parseLine(line);
      if (!row || (row.type !== "assistant" && row.type !== "user")) continue;
      const message = row.message;
      if (!message) continue;
      const blocks = Array.isArray(message.content) ? message.content : null;
      if (row.type === "assistant") {
        if (message.model) session.model = message.model;
        if (row.effort) session.effort = row.effort;
        else if (row.perTurnEffort && !session.effort) session.effort = row.perTurnEffort;
        const usage = message.usage;
        const messageId = message.id;
        if (usage && typeof messageId === "string" && !countedMessages.has(messageId)) {
          countedMessages.add(messageId);
          session.input += Number(usage.input_tokens) || 0;
          session.output += Number(usage.output_tokens) || 0;
          session.cache += (Number(usage.cache_creation_input_tokens) || 0)
            + (Number(usage.cache_read_input_tokens) || 0);
        }
        for (const block of blocks ?? []) {
          if (block?.type === "tool_use") noteTool(session, block.name, JSON.stringify(block.input ?? ""));
        }
      } else {
        if (row.isMeta) continue;
        const results = (blocks ?? []).filter((block) => block?.type === "tool_result");
        if (results.length > 0) {
          session.toolErrors += results.filter((block) => block.is_error === true).length;
          continue;
        }
        const text = textOf(message.content);
        if (!text || INJECTED_HEAD.some((marker) => text.trimStart().startsWith(marker))) continue;
        noteUserText(session, text);
      }
    }
    session.wallSeconds = Math.max(0, Math.round((endedMs - startedMs) / 1000));
    sessions.push(session);
  }
  return sessions;
}

function codexSessions() {
  const sessions = [];
  for (const file of dayFiles("codex")) {
    const meta = headRows(file)[0];
    const payload = meta?.type === "session_meta" ? meta.payload : null;
    if (!payload || !inDay(Date.parse(payload.timestamp))) continue;
    const lines = rawLines(file);
    const startedMs = Date.parse(payload.timestamp);
    const session = newSession("codex", payload.id ?? payload.session_id, payload.cwd, startedMs);
    const endedMs = lastTimestampMs(lines, startedMs);
    let totals = null;
    for (const line of lines) {
      const row = parseLine(line);
      if (!row) continue;
      const body = row.payload;
      if (!body) continue;
      if (row.type === "turn_context") {
        if (body.model) session.model = body.model;
        if (body.effort) session.effort = body.effort;
      } else if (row.type === "event_msg" && body.type === "token_count") {
        if (body.info?.total_token_usage) totals = body.info.total_token_usage;
      } else if (row.type === "event_msg" && body.type === "item_completed") {
        const item = body.item;
        if (!item) continue;
        if (item.type === "CommandExecution") {
          noteTool(session, "exec", item.command);
          if (item.status === "failed" || (Number.isFinite(item.exit_code) && item.exit_code !== 0)) session.toolErrors += 1;
        } else if (item.type === "McpToolCall") {
          noteTool(session, item.tool ?? item.server, JSON.stringify(item.arguments ?? ""));
          if (item.status === "failed") session.toolErrors += 1;
        } else if (item.type === "UserMessage") {
          noteUserText(session, textOf(item.content));
        }
      }
    }
    if (totals) {
      session.input = Number(totals.input_tokens) || 0;
      session.output = Number(totals.output_tokens) || 0;
      session.cache = (Number(totals.cached_input_tokens) || 0) + (Number(totals.cache_write_input_tokens) || 0);
    }
    session.wallSeconds = Math.max(0, Math.round((endedMs - startedMs) / 1000));
    sessions.push(session);
  }
  return sessions;
}

// --- rendering --------------------------------------------------------------

const dash = (value) => (value === null || value === undefined || value === "" ? "-" : String(value));
const cell = (value) => dash(value).replaceAll("|", "/").replaceAll("\n", " ");

function frictionTotal(session, retries) {
  return session.toolErrors + retries + session.corrections.length;
}

function render(sessions) {
  const rows = sessions
    .map((session) => ({ session, ...retryStats(session) }))
    .map((entry) => ({ ...entry, total: frictionTotal(entry.session, entry.retries) }))
    .sort((a, b) => a.session.startedMs - b.session.startedMs);
  const lines = [];
  lines.push(`# Session digest ${dayName}`);
  lines.push("");
  lines.push(`Sessions read: ${rows.length} (claude ${rows.filter((r) => r.session.harness === "claude").length},`
    + ` pi ${rows.filter((r) => r.session.harness === "pi").length},`
    + ` codex ${rows.filter((r) => r.session.harness === "codex").length}).`);
  lines.push("Counts only; a correction quote is capped at 120 characters and no assistant text, tool output, or file content is stored.");
  lines.push("");
  lines.push("| session | harness | place | task | model | effort | in | out | cache | wall_s | tools | errs | retries | turns | corr |");
  lines.push("|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
  for (const row of rows) {
    const s = row.session;
    lines.push(`| ${cell(s.session)} | ${cell(s.harness)} | ${cell(placeLabel(s.cwd))} | ${cell(taskLabel(s))} |`
      + ` ${cell(s.model)} | ${cell(s.effort)} | ${s.input} | ${s.output} | ${s.cache} | ${s.wallSeconds} |`
      + ` ${s.toolCalls} | ${s.toolErrors} | ${row.retries} | ${s.userTurns} | ${s.corrections.length} |`);
  }
  lines.push("");

  lines.push("## Corrections");
  lines.push("");
  const quotes = rows.flatMap((row) => row.session.corrections
    .map((quote) => `- \`${row.session.session}\` (${row.session.harness}, task ${taskLabel(row.session)}): "${quote}"`));
  lines.push(...(quotes.length > 0 ? quotes : ["No captain correction crossed the redirect markers."]));
  lines.push("");

  lines.push("## Friction");
  lines.push("");
  const friction = rows.filter((row) => row.total > 0)
    .sort((a, b) => b.total - a.total || b.session.toolErrors - a.session.toolErrors)
    .slice(0, FRICTION_TOP);
  if (friction.length === 0) {
    lines.push("No friction: every session recorded zero tool errors, retries, and corrections.");
  } else {
    friction.forEach((row, index) => {
      const s = row.session;
      lines.push(`${index + 1}. \`${s.session}\` ${s.harness} task=${taskLabel(s)} model=${dash(s.model)}`
        + ` errors=${s.toolErrors} retries=${row.retries} corrections=${s.corrections.length} total=${row.total}`);
    });
  }
  lines.push("");

  lines.push("## Candidates");
  lines.push("");
  const candidates = [];
  for (const row of rows) {
    const s = row.session;
    for (const rule of CANDIDATE_RULES) {
      const value = rule.key === "retries" ? row.retries
        : rule.key === "corrections" ? s.corrections.length : s.toolErrors;
      if (value < rule.min) continue;
      const pattern = rule.key === "retries" ? `${value} identical retries of \`${row.topTool}\``
        : rule.key === "corrections" ? `${value} captain corrections`
          : `${value} tool errors, mostly \`${row.topTool}\``;
      candidates.push({ value, line: `- \`${s.session}\` (${s.harness}, ${taskLabel(s)}): ${pattern} - likely owner: ${rule.owner}.` });
    }
  }
  candidates.sort((a, b) => b.value - a.value);
  lines.push(...(candidates.length > 0
    ? candidates.slice(0, CANDIDATE_MAX).map((entry) => entry.line)
    : ["Nothing notable: no session crossed a friction threshold, so there is no candidate to propose."]));
  lines.push("");
  return lines.join("\n");
}

// --- write ------------------------------------------------------------------

const sessions = [...claudeSessions(), ...piSessions(), ...codexSessions()];
fs.mkdirSync(outDir, { recursive: true, mode: 0o700 });
const target = path.join(outDir, `${dayName}.md`);
fs.writeFileSync(target, `${render(sessions)}\n`, { mode: 0o600 });
fs.chmodSync(target, 0o600);
process.stdout.write(`WROTE ${target}\n`);
