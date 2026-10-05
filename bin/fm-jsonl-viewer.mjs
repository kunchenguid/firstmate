#!/usr/bin/env node
// fm-jsonl-viewer.mjs - token-protected, read-only browser dashboard for the
// current Firstmate home's tasks and canonical task documents, plus ShortTask
// journals and supervision branch sessions.
//
// Usage:
//   FM_HOME=/absolute/home FM_JSONL_VIEWER_TOKEN_FILE=/private/token-file \
//     node bin/fm-jsonl-viewer.mjs [--host 0.0.0.0] [--port 17847]
//
// The token is accepted only through a protected file or the environment and
// is never printed. A token file must be absolute, owned by this user, regular,
// not a symlink, and grant no permissions to group or other users.
// Static UI assets contain no private data; every discovery/read endpoint
// requires Authorization: Bearer <token>. Only regular, non-symlink JSONL files
// below state/short-agents and state/branch-session and canonical
// data/<task>/{report.md,brief.md} files are eligible as content artifacts.

import { timingSafeEqual } from "node:crypto";
import { execFile, execFileSync } from "node:child_process";
import { constants as fsConstants, closeSync, fstatSync, lstatSync, openSync, readSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import http from "node:http";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_HOST = "0.0.0.0";
const DEFAULT_PORT = 17847;
const MAX_EVENTS = 200;
const TARGET_PAGE_BYTES = 1024 * 1024;
const MAX_LINE_BYTES = 8 * 1024 * 1024;
const TAIL_BYTES = 512 * 1024;
const READ_CHUNK_BYTES = 64 * 1024;
const MAX_REPORT_BYTES = 8 * 1024 * 1024;
const FLEET_SNAPSHOT_TIMEOUT_MS = 60000;
const TASK_RECORD_TIMEOUT_MS = 15000;
const TASK_OVERVIEW_CACHE_TTL_MS = 2000;
const TASK_CATEGORY_PRIORITY = new Map([
  ["processing", 0],
  ["held", 1],
  ["completed", 2],
  ["history", 3],
]);

function taskSortPriority(task) {
  return task.status === "Needs reconciliation"
    ? TASK_CATEGORY_PRIORITY.get("completed")
    : TASK_CATEGORY_PRIORITY.get(task.category) ?? TASK_CATEGORY_PRIORITY.size;
}

let taskOverviewCache = null;
let taskOverviewInFlight = null;
let taskOverviewRefreshError = null;

function usage(stream = process.stdout) {
  stream.write("FM_HOME=/absolute/home FM_JSONL_VIEWER_TOKEN_FILE=/private/token-file node bin/fm-jsonl-viewer.mjs [--host HOST] [--port PORT]\n");
}

function fail(message) {
  process.stderr.write(`fm-jsonl-viewer: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const options = { host: process.env.FM_JSONL_VIEWER_HOST || DEFAULT_HOST, port: Number(process.env.FM_JSONL_VIEWER_PORT || DEFAULT_PORT), home: process.env.FM_HOME || "" };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") return { help: true };
    if (!["--host", "--port", "--home"].includes(argument) || index + 1 >= argv.length) fail(`unknown or incomplete argument ${argument}`);
    const value = argv[index += 1];
    if (argument === "--host") options.host = value;
    if (argument === "--port") options.port = Number(value);
    if (argument === "--home") options.home = value;
  }
  if (!options.home || !isAbsolute(options.home)) fail("FM_HOME or --home must be an absolute existing Firstmate home");
  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) fail("port must be an integer from 0 through 65535");
  if (!options.host) fail("host must not be empty");
  return options;
}

function json(res, status, body) {
  const encoded = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": encoded.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  res.end(encoded);
}

function text(res, status, body, contentType) {
  const encoded = Buffer.from(body);
  res.writeHead(status, {
    "Content-Type": contentType,
    "Content-Length": encoded.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  });
  res.end(encoded);
}

function authorized(req, token) {
  const prefix = "Bearer ";
  const header = req.headers.authorization || "";
  if (!header.startsWith(prefix)) return false;
  const supplied = Buffer.from(header.slice(prefix.length));
  const expected = Buffer.from(token);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function accessToken() {
  const direct = process.env.FM_JSONL_VIEWER_TOKEN || "";
  const tokenFile = process.env.FM_JSONL_VIEWER_TOKEN_FILE || "";
  if (direct && tokenFile) fail("set only one of FM_JSONL_VIEWER_TOKEN and FM_JSONL_VIEWER_TOKEN_FILE");
  let token = direct;
  if (tokenFile) {
    if (!isAbsolute(tokenFile)) fail("FM_JSONL_VIEWER_TOKEN_FILE must be absolute");
    let info;
    try { info = lstatSync(tokenFile); } catch { fail("FM_JSONL_VIEWER_TOKEN_FILE is unreadable"); }
    if (!info.isFile() || info.isSymbolicLink()) fail("FM_JSONL_VIEWER_TOKEN_FILE must be a regular non-symlink file");
    if (typeof process.getuid === "function" && info.uid !== process.getuid()) fail("FM_JSONL_VIEWER_TOKEN_FILE must be owned by the current user");
    if ((info.mode & 0o077) !== 0) fail("FM_JSONL_VIEWER_TOKEN_FILE must not grant group or other access");
    token = readFileSync(tokenFile, "utf8").replace(/\r?\n$/, "");
    if (token.includes("\n") || token.includes("\r")) fail("FM_JSONL_VIEWER_TOKEN_FILE must contain one token line");
  }
  if (Buffer.byteLength(token) < 16) fail("the viewer access token must contain at least 16 bytes");
  return token;
}

function inside(root, candidate) {
  const rel = relative(root, candidate);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

function existingRoot(home, suffix) {
  const candidate = join(home, ...suffix);
  try {
    const info = lstatSync(candidate);
    if (!info.isDirectory() || info.isSymbolicLink()) return null;
    const canonical = realpathSync(candidate);
    return inside(home, canonical) ? canonical : null;
  } catch {
    return null;
  }
}

function regularNoSymlink(path) {
  try {
    const info = lstatSync(path);
    return info.isFile() && !info.isSymbolicLink();
  } catch {
    return false;
  }
}

function safeFile(root, candidate) {
  if (!root || !regularNoSymlink(candidate)) return null;
  try {
    const canonical = realpathSync(candidate);
    if (!inside(root, canonical) || extname(canonical) !== ".jsonl") return null;
    return canonical;
  } catch {
    return null;
  }
}

function safeMarkdownFile(root, candidate) {
  if (!root || !regularNoSymlink(candidate)) return null;
  try {
    const canonical = realpathSync(candidate);
    if (!inside(root, canonical) || extname(canonical) !== ".md") return null;
    return canonical;
  } catch {
    return null;
  }
}

function taskIdPathSafe(id) {
  return typeof id === "string"
    && id.length > 0
    && id.length <= 255
    && !id.startsWith(".")
    && /^[A-Za-z0-9._-]+$/.test(id);
}

function listSessions(roots) {
  const sessions = [];
  if (roots.short) {
    let ids = [];
    try { ids = readdirSync(roots.short).filter(name => /^short-[a-f0-9]{64}$/.test(name)); } catch { ids = []; }
    for (const id of ids) {
      const directory = join(roots.short, id);
      let directoryInfo;
      try { directoryInfo = lstatSync(directory); } catch { continue; }
      if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink()) continue;
      const file = safeFile(roots.short, join(directory, "journal.jsonl"));
      if (!file) continue;
      let info;
      try { info = lstatSync(file); } catch { continue; }
      if (!info.isFile() || info.isSymbolicLink()) continue;
      sessions.push({ source: "short", id, label: id, bytes: info.size, modifiedAt: info.mtime.toISOString() });
    }
  }
  if (roots.supervisor) {
    let ids = [];
    try { ids = readdirSync(roots.supervisor).filter(name => /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}\.jsonl$/.test(name)); } catch { ids = []; }
    for (const id of ids) {
      const file = safeFile(roots.supervisor, join(roots.supervisor, id));
      if (!file) continue;
      let info;
      try { info = lstatSync(file); } catch { continue; }
      if (!info.isFile() || info.isSymbolicLink()) continue;
      sessions.push({ source: "supervisor", id, label: id.replace(/\.jsonl$/, ""), bytes: info.size, modifiedAt: info.mtime.toISOString() });
    }
  }
  return sessions.sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt));
}

function listReports(root, ids) {
  if (!root) return [];
  const reports = [];
  for (const id of ids) {
    const directory = join(root, id);
    let directoryInfo;
    try { directoryInfo = lstatSync(directory); } catch { continue; }
    if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink()) continue;
    const file = safeMarkdownFile(root, join(directory, "report.md"));
    if (!file) continue;
    let info;
    try { info = lstatSync(file); } catch { continue; }
    if (!info.isFile() || info.isSymbolicLink()) continue;
    reports.push({ source: "report", id, label: id, bytes: info.size, modifiedAt: info.mtime.toISOString() });
  }
  return reports.sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt));
}

function listTaskDocuments(root, ids) {
  if (!root) return [];
  const documents = [];
  for (const id of ids) {
    const available = resolveTaskDocuments(root, id);
    const sources = ["report", "brief"].filter(source => available?.[source]);
    if (!sources.length) continue;
    const details = [];
    for (const source of sources) {
      let info;
      try { info = lstatSync(available[source]); } catch { continue; }
      if (!info.isFile() || info.isSymbolicLink()) continue;
      details.push({ source, bytes: info.size, modifiedAt: info.mtime.toISOString() });
    }
    if (!details.length) continue;
    const preferred = details.find(document => document.source === "report") || details[0];
    documents.push({
      source: preferred.source,
      id,
      bytes: preferred.bytes,
      modifiedAt: details.map(document => document.modifiedAt).sort().at(-1),
      documentTypes: details.map(document => document.source),
    });
  }
  return documents;
}

function taskCommandEnvironment(home) {
  const environment = { ...process.env, FM_HOME: home };
  delete environment.FM_JSONL_VIEWER_TOKEN;
  delete environment.FM_JSONL_VIEWER_TOKEN_FILE;
  return environment;
}

function taskRecords(codeRoot, dataRoot, home, id = null) {
  return JSON.parse(execFileSync("python3", [join(codeRoot, "bin", "fm-task-record.py"), "--data", dataRoot,
    ...(id === null ? ["inventory"] : ["progress", id])], {
    encoding: "utf8", env: taskCommandEnvironment(home), timeout: TASK_RECORD_TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024,
  }));
}

function taskDocumentGate(codeRoot, dataRoot, home, id) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/.test(id)) return { status: 404, body: { error: "task not found" } };
  try { taskRecords(codeRoot, dataRoot, home, id); return null; }
  catch (error) {
    return String(error.stderr || "").trim() === "code: NOT_FOUND"
      ? { status: 404, body: { error: "task not found" } }
      : { status: 503, body: { error: "task record is unavailable" } };
  }
}

function taskOverview(home, roots, codeRoot) {
  const environment = taskCommandEnvironment(home);
  const raw = execFileSync(join(codeRoot, "bin", "fm-fleet-snapshot.sh"), ["--json"], {
    encoding: "utf8",
    env: environment,
    timeout: FLEET_SNAPSHOT_TIMEOUT_MS,
    maxBuffer: 32 * 1024 * 1024,
  });
  const snapshot = JSON.parse(raw);
  if (!Array.isArray(snapshot.tasks) || !Array.isArray(snapshot.backlog?.records)
    || snapshot.backlog.records.some(record => !taskIdPathSafe(record?.id)
      || !["queued", "in_flight", "done", "archived"].includes(record.state)
      || !["active", "queued", "parked", "done", "archive_done"].includes(record.record_disposition)
      || typeof record.title !== "string" || typeof record.kind !== "string")) {
    throw new Error("unsupported task snapshot");
  }
  const records = snapshot.backlog.records;
  const documents = new Map(listTaskDocuments(roots.reports, records.map(record => record.id)).map(document => [document.id, document]));
  const observations = new Map(snapshot.tasks.map(task => [task.id, task]));
  const items = new Map(records.map(record => {
    const task = observations.get(record.id);
    const document = documents.get(record.id);
    return [record.id, {
      id: record.id, title: record.title, backlogState: record.state, kind: record.kind, project: record.repo,
      recordDisposition: record.record_disposition, holdKind: record.hold_kind, holdReason: record.hold_reason,
      blockedBy: record.unresolved_blocker_ids, progress: record.compact_progress,
      executionHarness: task?.harness || task?.provider || null, executionModel: task?.model || null,
      executionState: task?.current_state?.state || null,
      hasDocument: Boolean(document), documentType: document?.source,
      documentTypes: document?.documentTypes, documentModifiedAt: document?.modifiedAt,
    }];
  }));
  const tasks = [...items.values()].map(item => {
    const disposition = item.recordDisposition;
    const terminal = ["done", "archive_done"].includes(disposition);
    const held = !terminal && (item.holdKind || (item.blockedBy || []).length > 0);
    const category = disposition === "archive_done" ? "history" : disposition === "done" ? "completed"
      : held || disposition !== "active" ? "held" : "processing";
    const status = disposition === "archive_done" ? "Archived" : disposition === "done" ? "Completed"
      : held ? item.holdKind === "parked" ? "Parked" : (item.blockedBy || []).length ? "Blocked" : "Waiting"
      : disposition === "active" ? "Processing" : "Queued";
    const wait = terminal ? null : (item.blockedBy || []).length ? `Blocked by ${item.blockedBy.join(", ")}`
      : held ? item.holdReason || status : category === "held" ? status : null;
    return {
      id: item.id,
      title: item.title || item.id,
      category,
      status,
      kind: item.kind || null,
      project: item.project || null,
      wait,
      warning: null,
      state: item.backlogState,
      progress: terminal ? null : item.progress,
      executionHarness: terminal ? null : item.executionHarness,
      executionModel: terminal ? null : item.executionModel,
      executionState: terminal ? null : item.executionState,
      hasDocument: Boolean(item.hasDocument),
      documentType: item.documentType || null,
      documentTypes: item.documentTypes || [],
      documentModifiedAt: item.documentModifiedAt || null,
    };
  }).sort((left, right) => taskSortPriority(left)
    - taskSortPriority(right)
    || left.title.localeCompare(right.title));
  return {
    generatedAt: snapshot.generated,
    tasks,
    warning: null,
  };
}

function taskOverviewAgeMs(cache, now = Date.now()) {
  const generatedAt = Date.parse(cache.body.generatedAt);
  return Math.max(0, now - (Number.isFinite(generatedAt) ? generatedAt : cache.servedAt));
}

function startTaskOverviewRefresh(home, codeRoot) {
  if (!taskOverviewInFlight) {
    const workerEnvironment = { ...process.env, FM_HOME: home, FM_JSONL_VIEWER_TASK_WORKER: "1" };
    delete workerEnvironment.FM_JSONL_VIEWER_TOKEN;
    delete workerEnvironment.FM_JSONL_VIEWER_TOKEN_FILE;
    taskOverviewInFlight = new Promise((resolve, reject) => {
      execFile(process.execPath, [fileURLToPath(import.meta.url), "--task-overview-worker", "--home", home], {
        encoding: "utf8",
        env: workerEnvironment,
        timeout: FLEET_SNAPSHOT_TIMEOUT_MS,
        maxBuffer: 32 * 1024 * 1024,
      }, (error, stdout) => error ? reject(error) : resolve(JSON.parse(stdout)));
    }).then(body => {
      taskOverviewCache = { home, codeRoot, servedAt: Date.now(), body };
      taskOverviewRefreshError = null;
      return body;
    }, error => {
      taskOverviewRefreshError = "Task refresh failed; cached snapshot remains visible.";
      throw error;
    }).finally(() => { taskOverviewInFlight = null; });
  }
  return taskOverviewInFlight;
}

async function cachedTaskOverview(home, roots, codeRoot) {
  const now = Date.now();
  const matchingCache = taskOverviewCache
    && taskOverviewCache.home === home
    && taskOverviewCache.codeRoot === codeRoot
    ? taskOverviewCache
    : null;
  if (matchingCache && now - matchingCache.servedAt < TASK_OVERVIEW_CACHE_TTL_MS) {
    return {
      ...matchingCache.body,
      cacheHit: true,
      cacheAgeMs: taskOverviewAgeMs(matchingCache, now),
      refreshing: false,
      refreshError: null,
    };
  }
  const refresh = startTaskOverviewRefresh(home, codeRoot);
  if (matchingCache) {
    refresh.catch(() => {});
    return {
      ...matchingCache.body,
      cacheHit: true,
      cacheAgeMs: taskOverviewAgeMs(matchingCache, now),
      refreshing: true,
      refreshError: taskOverviewRefreshError,
    };
  }
  const body = await refresh;
  return { ...body, cacheHit: false, cacheAgeMs: taskOverviewAgeMs(taskOverviewCache), refreshing: false, refreshError: null };
}

function resolveSelection(roots, source, id) {
  if (source === "short" && /^short-[a-f0-9]{64}$/.test(id)) {
    const directory = join(roots.short || "", id);
    try {
      const info = lstatSync(directory);
      if (!roots.short || !info.isDirectory() || info.isSymbolicLink() || !inside(roots.short, realpathSync(directory))) return null;
    } catch { return null; }
    return safeFile(roots.short, join(directory, "journal.jsonl"));
  }
  if (source === "supervisor" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}\.jsonl$/.test(id)) {
    return safeFile(roots.supervisor, join(roots.supervisor || "", id));
  }
  return null;
}

function openVerified(file, root) {
  const before = lstatSync(file);
  if (!before.isFile() || before.isSymbolicLink()) throw new Error("selected artifact is not a regular file");
  const canonical = realpathSync(file);
  if (!inside(root, canonical)) throw new Error("selected artifact escaped its allowed root");
  const fd = openSync(canonical, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW || 0));
  const after = fstatSync(fd);
  if (!after.isFile() || before.dev !== after.dev || before.ino !== after.ino) {
    closeSync(fd);
    throw new Error("selected artifact changed during open");
  }
  return { fd, info: after, identity: `${after.dev}:${after.ino}` };
}

function resolveReport(root, id) {
  if (!root || !taskIdPathSafe(id)) return null;
  const directory = join(root, id);
  try {
    const info = lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || !inside(root, realpathSync(directory))) return null;
  } catch { return null; }
  const file = safeMarkdownFile(root, join(directory, "report.md"));
  return file ? { source: "report", file } : null;
}

function resolveTaskDocuments(root, id) {
  if (!root || !taskIdPathSafe(id)) return null;
  const directory = join(root, id);
  try {
    const info = lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || !inside(root, realpathSync(directory))) return null;
  } catch { return null; }
  const documents = {};
  for (const [source, name] of [["report", "report.md"], ["brief", "brief.md"]]) {
    const file = safeMarkdownFile(root, join(directory, name));
    if (file) documents[source] = file;
  }
  return documents;
}

function resolveTaskDocument(root, id, requestedSource = "") {
  if (requestedSource && !["brief", "report"].includes(requestedSource)) return null;
  const documents = resolveTaskDocuments(root, id);
  if (!documents) return null;
  const source = requestedSource || (documents.report ? "report" : documents.brief ? "brief" : "");
  return source && documents[source] ? { source, file: documents[source] } : null;
}

function readMarkdownDocument(root, id, resolver, noun) {
  const document = resolver(root, id);
  if (!document) return { status: 404, body: { error: `unknown or disallowed ${noun}` } };
  let opened;
  try { opened = openVerified(document.file, root); }
  catch (error) { return { status: 409, body: { error: error.message } }; }
  try {
    if (opened.info.size > MAX_REPORT_BYTES) {
      return { status: 413, body: { error: `${noun} exceeds the 8 MiB display limit` } };
    }
    const content = Buffer.alloc(opened.info.size);
    let offset = 0;
    while (offset < content.length) {
      const count = readSync(opened.fd, content, offset, content.length - offset, offset);
      if (!count) break;
      offset += count;
    }
    const after = fstatSync(opened.fd);
    if (offset !== content.length || after.size !== opened.info.size || after.mtimeMs !== opened.info.mtimeMs) {
      return { status: 409, body: { error: `selected ${noun} changed during read` } };
    }
    return {
      status: 200,
      body: {
        source: document.source,
        id,
        identity: opened.identity,
        size: opened.info.size,
        modifiedAt: opened.info.mtime.toISOString(),
        content: content.toString("utf8"),
      },
    };
  } finally {
    closeSync(opened.fd);
  }
}

function readReport(root, id) {
  return readMarkdownDocument(root, id, resolveReport, "report");
}

function readTaskDocument(root, id, source) {
  return readMarkdownDocument(root, id, (documentsRoot, taskId) => resolveTaskDocument(documentsRoot, taskId, source), "task document");
}

function tailStart(fd, size) {
  let completeEnd = size;
  let trailingPartialBytes = 0;
  if (size > 0) {
    const last = Buffer.alloc(1);
    readSync(fd, last, 0, 1, size - 1);
    if (last[0] !== 0x0a) {
      completeEnd = 0;
      let position = size;
      while (position > 0) {
        const begin = Math.max(0, position - READ_CHUNK_BYTES);
        const chunk = Buffer.alloc(position - begin);
        const count = readSync(fd, chunk, 0, chunk.length, begin);
        const newline = chunk.subarray(0, count).lastIndexOf(0x0a);
        if (newline !== -1) {
          completeEnd = begin + newline + 1;
          break;
        }
        position = begin;
      }
      trailingPartialBytes = size - completeEnd;
    }
  }
  const targetBegin = Math.max(0, completeEnd - TAIL_BYTES);
  let initialOffset = 0;
  let position = targetBegin;
  while (position > 0) {
    const begin = Math.max(0, position - READ_CHUNK_BYTES);
    const chunk = Buffer.alloc(position - begin);
    const count = readSync(fd, chunk, 0, chunk.length, begin);
    const newline = chunk.subarray(0, count).lastIndexOf(0x0a);
    if (newline !== -1) {
      initialOffset = begin + newline + 1;
      break;
    }
    position = begin;
  }
  const newlineOffsets = [];
  position = initialOffset;
  while (position < completeEnd) {
    const chunk = Buffer.alloc(Math.min(READ_CHUNK_BYTES, completeEnd - position));
    const count = readSync(fd, chunk, 0, chunk.length, position);
    if (!count) break;
    for (let index = 0; index < count; index += 1) {
      if (chunk[index] === 0x0a) newlineOffsets.push(position + index);
    }
    position += count;
  }
  const skippedCompleteLines = Math.max(0, newlineOffsets.length - MAX_EVENTS);
  const offset = skippedCompleteLines ? newlineOffsets[skippedCompleteLines - 1] + 1 : initialOffset;
  return { offset, omittedPrefixBytes: offset, trailingPartialBytes };
}

function parseLine(bytes, lineOffset) {
  if (bytes.length > MAX_LINE_BYTES) {
    return { offset: lineOffset, bytes: bytes.length, error: "line_too_large", raw: null, value: null };
  }
  const raw = bytes.toString("utf8").replace(/\r$/, "");
  try {
    return { offset: lineOffset, bytes: bytes.length, raw, value: JSON.parse(raw) };
  } catch (error) {
    return { offset: lineOffset, bytes: bytes.length, error: "malformed_json", detail: String(error.message), raw, value: null };
  }
}

function readPage(fd, size, requestedOffset, tailPage = false) {
  const events = [];
  let position = requestedOffset;
  let lineOffset = position;
  let lineBytes = 0;
  let storedBytes = 0;
  let parts = [];
  let completeThrough = requestedOffset;
  let stop = false;

  while (position < size && !stop) {
    const buffer = Buffer.alloc(Math.min(READ_CHUNK_BYTES, size - position));
    const count = readSync(fd, buffer, 0, buffer.length, position);
    if (!count) break;
    let segmentStart = 0;
    for (let index = 0; index < count; index += 1) {
      if (buffer[index] !== 0x0a) continue;
      const segment = buffer.subarray(segmentStart, index);
      lineBytes += segment.length;
      if (storedBytes <= MAX_LINE_BYTES) {
        parts.push(segment);
        storedBytes += segment.length;
      }
      events.push(lineBytes > MAX_LINE_BYTES
        ? { offset: lineOffset, bytes: lineBytes, error: "line_too_large", raw: null, value: null }
        : parseLine(Buffer.concat(parts, storedBytes), lineOffset));
      completeThrough = position + index + 1;
      lineOffset = completeThrough;
      lineBytes = 0;
      storedBytes = 0;
      parts = [];
      segmentStart = index + 1;
      if (events.length >= MAX_EVENTS || (!tailPage && completeThrough - requestedOffset >= TARGET_PAGE_BYTES)) {
        stop = true;
        break;
      }
    }
    if (stop) break;
    if (segmentStart < count) {
      const segment = buffer.subarray(segmentStart, count);
      lineBytes += segment.length;
      if (storedBytes <= MAX_LINE_BYTES) {
        const remaining = Math.max(0, MAX_LINE_BYTES + 1 - storedBytes);
        parts.push(segment.subarray(0, remaining));
        storedBytes += Math.min(segment.length, remaining);
      }
    }
    position += count;
  }
  return { events, nextCursor: completeThrough, partialBytes: stop ? 0 : size - completeThrough, eof: completeThrough === size };
}

function readEvents(roots, source, id, query) {
  const file = resolveSelection(roots, source, id);
  if (!file) return { status: 404, body: { error: "unknown or disallowed journal" } };
  const root = source === "short" ? roots.short : roots.supervisor;
  let opened;
  try { opened = openVerified(file, root); }
  catch (error) { return { status: 409, body: { error: error.message } }; }
  try {
    let cursor = query.get("cursor") === "tail" ? "tail" : Number(query.get("cursor") || 0);
    if (cursor !== "tail" && (!Number.isSafeInteger(cursor) || cursor < 0)) return { status: 400, body: { error: "cursor must be a non-negative integer or tail" } };
    const priorIdentity = query.get("identity") || "";
    let reset = null;
    let omittedPrefixBytes = 0;
    if (priorIdentity && priorIdentity !== opened.identity) {
      reset = "rotated";
      cursor = "tail";
    } else if (cursor !== "tail" && cursor > opened.info.size) {
      reset = "truncated";
      cursor = "tail";
    }
    const tailPage = cursor === "tail";
    let trailingPartialBytes = 0;
    if (cursor === "tail") {
      const tail = tailStart(opened.fd, opened.info.size);
      cursor = tail.offset;
      omittedPrefixBytes = tail.omittedPrefixBytes;
      trailingPartialBytes = tail.trailingPartialBytes;
    }
    const page = readPage(opened.fd, opened.info.size, cursor, tailPage);
    if (trailingPartialBytes && page.nextCursor === opened.info.size - trailingPartialBytes) {
      page.partialBytes = trailingPartialBytes;
      page.eof = false;
    }
    return { status: 200, body: { source, id, identity: opened.identity, size: opened.info.size, reset, omittedPrefixBytes, ...page } };
  } finally {
    closeSync(opened.fd);
  }
}

function serve() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) { usage(); return; }
  const token = accessToken();
  let home;
  try { home = realpathSync(options.home); } catch { fail("Firstmate home does not exist"); }
  const roots = {
    short: existingRoot(home, ["state", "short-agents"]),
    supervisor: existingRoot(home, ["state", "branch-session"]),
    reports: existingRoot(home, ["data"]),
  };
  const codeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const assetRoot = resolve(codeRoot, "web/jsonl-viewer");
  const assets = {
    "/": ["index.html", "text/html; charset=utf-8"],
    "/app.js": ["app.js", "text/javascript; charset=utf-8"],
    "/style.css": ["style.css", "text/css; charset=utf-8"],
  };

  const server = http.createServer((req, res) => {
    if (req.method !== "GET") return json(res, 405, { error: "read-only server" });
    let url;
    try { url = new URL(req.url || "/", "http://viewer.invalid"); }
    catch { return json(res, 400, { error: "invalid request URL" }); }
    if (req.headers.accept?.includes("text/html") && /^(?:\/login|\/dashboard|\/reports|\/report\/[A-Za-z0-9._-]+|\/journal\/(?:supervisor|short)(?:\/[A-Za-z0-9._-]+)?)\/?$/.test(url.pathname)) {
      return text(res, 200, readFileSync(join(assetRoot, "index.html"), "utf8"), "text/html; charset=utf-8");
    }
    if (Object.hasOwn(assets, url.pathname)) {
      const [name, contentType] = assets[url.pathname];
      return text(res, 200, readFileSync(join(assetRoot, name), "utf8"), contentType);
    }
    if (!authorized(req, token)) {
      res.setHeader("WWW-Authenticate", 'Bearer realm="Firstmate JSONL viewer"');
      return json(res, 401, { error: "authorization required" });
    }
    if (url.pathname === "/api/sessions") {
      try {
        const inventory = taskRecords(codeRoot, roots.reports || join(home, "data"), home);
        return json(res, 200, {
          sessions: listSessions(roots), reports: listReports(roots.reports, inventory.tasks.map(record => record.id)),
          roots: { short: Boolean(roots.short), supervisor: Boolean(roots.supervisor), reports: Boolean(roots.reports) },
        });
      } catch { return json(res, 503, { error: "task reports are temporarily unavailable" }); }
    }
    if (url.pathname === "/api/tasks") {
      cachedTaskOverview(home, roots, codeRoot)
        .then(body => {
          if (url.searchParams.get("generation") === body.generatedAt) {
            const { tasks: _tasks, ...metadata } = body;
            return json(res, 200, { ...metadata, unchanged: true });
          }
          return json(res, 200, { ...body, unchanged: false });
        })
        .catch(() => json(res, 503, { error: "task overview is temporarily unavailable" }));
      return;
    }
    if (url.pathname === "/api/events") {
      const result = readEvents(roots, url.searchParams.get("source") || "", url.searchParams.get("id") || "", url.searchParams);
      return json(res, result.status, result.body);
    }
    if (url.pathname === "/api/report") {
      const gate = taskDocumentGate(codeRoot, roots.reports || join(home, "data"), home, url.searchParams.get("id") || "");
      if (gate) return json(res, gate.status, gate.body);
      const result = readReport(roots.reports, url.searchParams.get("id") || "");
      return json(res, result.status, result.body);
    }
    if (url.pathname === "/api/task-document") {
      const gate = taskDocumentGate(codeRoot, roots.reports || join(home, "data"), home, url.searchParams.get("id") || "");
      if (gate) return json(res, gate.status, gate.body);
      const result = readTaskDocument(roots.reports, url.searchParams.get("id") || "", url.searchParams.get("type") || "");
      return json(res, result.status, result.body);
    }
    return json(res, 404, { error: "not found" });
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.listen(options.port, options.host, () => {
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : options.port;
    process.stdout.write(`Firstmate JSONL viewer listening on http://${options.host}:${port}\n`);
  });
}

function runTaskOverviewWorker() {
  const options = parseArgs(process.argv.slice(2).filter(argument => argument !== "--task-overview-worker"));
  const home = realpathSync(options.home);
  const roots = {
    short: existingRoot(home, ["state", "short-agents"]),
    supervisor: existingRoot(home, ["state", "branch-session"]),
    reports: existingRoot(home, ["data"]),
  };
  const codeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  process.stdout.write(JSON.stringify(taskOverview(home, roots, codeRoot)));
}

if (process.argv.includes("--task-overview-worker")) runTaskOverviewWorker();
else serve();
