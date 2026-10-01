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
const TASK_DISPOSITION_TIMEOUT_MS = 15000;
const TASK_OVERVIEW_CACHE_TTL_MS = 2000;

let taskOverviewCache = null;
let taskOverviewInFlight = null;

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

function listReports(root) {
  if (!root) return [];
  let ids = [];
  try { ids = readdirSync(root).filter(taskIdPathSafe); } catch { return []; }
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

function listTaskDocuments(root) {
  if (!root) return [];
  let ids = [];
  try { ids = readdirSync(root).filter(taskIdPathSafe); } catch { return []; }
  const documents = [];
  for (const id of ids) {
    const document = resolveTaskDocument(root, id);
    if (!document) continue;
    let info;
    try { info = lstatSync(document.file); } catch { continue; }
    if (!info.isFile() || info.isSymbolicLink()) continue;
    documents.push({ source: document.source, id, bytes: info.size, modifiedAt: info.mtime.toISOString() });
  }
  return documents;
}

function taskCommandEnvironment(home) {
  const environment = { ...process.env, FM_HOME: home };
  delete environment.FM_JSONL_VIEWER_TOKEN;
  delete environment.FM_JSONL_VIEWER_TOKEN_FILE;
  return environment;
}

function taskDispositions(codeRoot, dataRoot, environment) {
  const library = join(codeRoot, "bin", "fm-task-disposition-lib.sh");
  const output = execFileSync("bash", ["-c", '. "$1"; fm_task_disposition_snapshot "$2"', "fm-jsonl-viewer", library, dataRoot], {
    encoding: "utf8",
    env: environment,
    timeout: TASK_DISPOSITION_TIMEOUT_MS,
    maxBuffer: 4 * 1024 * 1024,
  });
  const dispositions = new Map();
  for (const line of output.split("\n")) {
    if (!line) continue;
    const [id, disposition] = line.split("\t");
    if (/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(id) && /^(active|queued|done|archive_done|parked|ambiguous)$/.test(disposition)) {
      dispositions.set(id, disposition);
    }
  }
  return dispositions;
}

function lifecycleDispositions(codeRoot, dataRoot, environment) {
  const values = new Map();
  let ids = [];
  try { ids = readdirSync(dataRoot).filter(name => /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(name)); } catch { return values; }
  for (const id of ids) {
    const directory = join(dataRoot, id);
    const lifecycle = join(directory, "lifecycle.json");
    try {
      const directoryInfo = lstatSync(directory);
      if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink() || !inside(dataRoot, realpathSync(directory))) continue;
      if (!regularNoSymlink(lifecycle)) continue;
      const raw = execFileSync(join(codeRoot, "bin", "fm-task-state.sh"), ["lifecycle", id], {
        encoding: "utf8",
        env: environment,
        timeout: 3000,
        maxBuffer: 2 * 1024 * 1024,
      });
      const disposition = JSON.parse(raw).disposition;
      if (["open", "accepted", "archived"].includes(disposition)) values.set(id, disposition);
    } catch {
      values.set(id, "unknown");
    }
  }
  return values;
}

function taskOverview(home, roots, codeRoot) {
  const environment = taskCommandEnvironment(home);
  const dataRoot = roots.reports || join(home, "data");
  const raw = execFileSync(join(codeRoot, "bin", "fm-fleet-snapshot.sh"), ["--json"], {
    encoding: "utf8",
    env: environment,
    timeout: FLEET_SNAPSHOT_TIMEOUT_MS,
    maxBuffer: 32 * 1024 * 1024,
  });
  const snapshot = JSON.parse(raw);
  if (snapshot.schema !== "fm-fleet-snapshot.v1" || !Array.isArray(snapshot.tasks) || !Array.isArray(snapshot.backlog?.records)) {
    throw new Error("unsupported task snapshot");
  }
  const dispositions = taskDispositions(codeRoot, dataRoot, environment);
  const lifecycles = lifecycleDispositions(codeRoot, dataRoot, environment);
  const documents = new Map(listTaskDocuments(roots.reports).map(document => [document.id, document]));
  const items = new Map();
  const ensure = id => {
    if (!items.has(id)) items.set(id, { id, title: id });
    return items.get(id);
  };
  for (const record of snapshot.backlog.records) {
    if (!record?.structured || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(record.id || "")) continue;
    Object.assign(ensure(record.id), {
      title: record.title || record.id,
      backlogState: record.state || null,
      kind: record.kind || null,
      project: record.repo || null,
      holdKind: record.hold_kind || null,
      blockedBy: Array.isArray(record.unresolved_blocker_ids) ? record.unresolved_blocker_ids : [],
    });
  }
  for (const task of snapshot.tasks) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(task.id || "")) continue;
    Object.assign(ensure(task.id), {
      title: task.backlog?.title || task.id,
      backlogState: task.backlog?.state || null,
      kind: task.kind || task.backlog?.kind || null,
      project: task.backlog?.repo || task.project || null,
      currentState: task.current_state?.state || "unknown",
      recordDisposition: task.record_disposition || dispositions.get(task.id) || "unknown",
      lifecycleDisposition: task.lifecycle_disposition || lifecycles.get(task.id) || "legacy",
      openDecisionCount: Array.isArray(task.hints?.open_decisions) ? task.hints.open_decisions.length : 0,
      heldByDecision: Boolean(task.hints?.pending_decision || task.hints?.blocked_event),
      blockedBy: Array.isArray(task.backlog?.unresolved_blocker_ids) ? task.backlog.unresolved_blocker_ids : [],
      holdKind: task.backlog?.hold_kind || null,
    });
  }
  for (const [id, disposition] of dispositions) ensure(id).recordDisposition ||= disposition;
  for (const [id, disposition] of lifecycles) ensure(id).lifecycleDisposition ||= disposition;
  for (const [id, document] of documents) {
    const item = ensure(id);
    item.hasDocument = true;
    item.documentType = document.source;
    item.documentModifiedAt = document.modifiedAt;
  }
  const tasks = [...items.values()].map(item => {
    const disposition = item.recordDisposition || "unknown";
    const lifecycle = item.lifecycleDisposition || "legacy";
    const terminalConflict = ["working", "blocked", "parked"].includes(item.currentState)
      && (["done", "archive_done"].includes(disposition) || ["accepted", "archived"].includes(lifecycle));
    const held = item.heldByDecision || item.openDecisionCount > 0 || item.currentState === "blocked" || item.currentState === "parked"
      || item.holdKind === "parked" || (item.blockedBy || []).length > 0 || terminalConflict;
    let category = "held";
    let status = "Needs reconciliation";
    if (terminalConflict) {
      category = "held";
      status = "Completion conflict";
    } else if (lifecycle === "archived") {
      category = "history";
      status = "Cancelled";
    } else if (disposition === "archive_done") {
      category = "history";
      status = "Archived";
    } else if (!held && (lifecycle === "accepted" || disposition === "done")) {
      category = "completed";
      status = "Completed";
    } else if (held) {
      category = "held";
      status = item.holdKind === "parked" ? "Parked" : item.currentState === "blocked" ? "Blocked" : "Waiting";
    } else if (disposition === "active" || item.backlogState === "in_flight" || item.currentState === "working") {
      category = "processing";
      status = "Processing";
    } else if (disposition === "queued" || item.backlogState === "queued") {
      category = "held";
      status = "Queued";
    }
    let wait = null;
    if ((item.blockedBy || []).length) wait = `Blocked by ${item.blockedBy.join(", ")}`;
    else if (item.openDecisionCount > 0) wait = `${item.openDecisionCount} open decision${item.openDecisionCount === 1 ? "" : "s"}`;
    else if (category === "held") wait = status;
    return {
      id: item.id,
      title: item.title || item.id,
      category,
      status,
      kind: item.kind || null,
      project: item.project || null,
      wait,
      hasDocument: Boolean(item.hasDocument),
      documentType: item.documentType || null,
      documentModifiedAt: item.documentModifiedAt || null,
    };
  }).sort((left, right) => left.category.localeCompare(right.category) || left.title.localeCompare(right.title));
  return {
    generatedAt: snapshot.generated,
    tasks,
    warning: snapshot.main_inventory?.valid === false ? "Some current task records need reconciliation." : null,
  };
}

async function cachedTaskOverview(home, roots, codeRoot) {
  const now = Date.now();
  if (taskOverviewCache
    && taskOverviewCache.home === home
    && taskOverviewCache.codeRoot === codeRoot
    && now - taskOverviewCache.servedAt < TASK_OVERVIEW_CACHE_TTL_MS) {
    return { ...taskOverviewCache.body, cacheHit: true, cacheAgeMs: now - taskOverviewCache.servedAt };
  }
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
    }).finally(() => { taskOverviewInFlight = null; });
  }
  const body = await taskOverviewInFlight;
  taskOverviewCache = { home, codeRoot, servedAt: Date.now(), body };
  return { ...body, cacheHit: false, cacheAgeMs: 0 };
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

function resolveTaskDocument(root, id) {
  if (!root || !taskIdPathSafe(id)) return null;
  const directory = join(root, id);
  try {
    const info = lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || !inside(root, realpathSync(directory))) return null;
  } catch { return null; }
  for (const [source, name] of [["report", "report.md"], ["brief", "brief.md"]]) {
    const file = safeMarkdownFile(root, join(directory, name));
    if (file) return { source, file };
  }
  return null;
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

function readTaskDocument(root, id) {
  return readMarkdownDocument(root, id, resolveTaskDocument, "task document");
}

function tailStart(fd, size) {
  if (size <= TAIL_BYTES) return { offset: 0, omittedPrefixBytes: 0 };
  const begin = size - TAIL_BYTES;
  const probe = Buffer.alloc(size - begin);
  const count = readSync(fd, probe, 0, probe.length, begin);
  const newline = probe.subarray(0, count).indexOf(0x0a);
  const offset = newline === -1 ? 0 : begin + newline + 1;
  return { offset, omittedPrefixBytes: offset };
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

function readPage(fd, size, requestedOffset) {
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
      if (events.length >= MAX_EVENTS || completeThrough - requestedOffset >= TARGET_PAGE_BYTES) {
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
  return { events, nextCursor: completeThrough, partialBytes: stop ? 0 : size - completeThrough, eof: !stop && completeThrough === size };
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
      cursor = 0;
    } else if (cursor !== "tail" && cursor > opened.info.size) {
      reset = "truncated";
      cursor = 0;
    }
    if (cursor === "tail") {
      const tail = tailStart(opened.fd, opened.info.size);
      cursor = tail.offset;
      omittedPrefixBytes = tail.omittedPrefixBytes;
    }
    const page = readPage(opened.fd, opened.info.size, cursor);
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
    if (Object.hasOwn(assets, url.pathname)) {
      const [name, contentType] = assets[url.pathname];
      return text(res, 200, readFileSync(join(assetRoot, name), "utf8"), contentType);
    }
    if (!authorized(req, token)) {
      res.setHeader("WWW-Authenticate", 'Bearer realm="Firstmate JSONL viewer"');
      return json(res, 401, { error: "authorization required" });
    }
    if (url.pathname === "/api/sessions") return json(res, 200, {
      sessions: listSessions(roots),
      reports: listReports(roots.reports),
      roots: { short: Boolean(roots.short), supervisor: Boolean(roots.supervisor), reports: Boolean(roots.reports) },
    });
    if (url.pathname === "/api/tasks") {
      cachedTaskOverview(home, roots, codeRoot)
        .then(body => json(res, 200, body))
        .catch(() => json(res, 503, { error: "task overview is temporarily unavailable" }));
      return;
    }
    if (url.pathname === "/api/events") {
      const result = readEvents(roots, url.searchParams.get("source") || "", url.searchParams.get("id") || "", url.searchParams);
      return json(res, result.status, result.body);
    }
    if (url.pathname === "/api/report") {
      const result = readReport(roots.reports, url.searchParams.get("id") || "");
      return json(res, result.status, result.body);
    }
    if (url.pathname === "/api/task-document") {
      const result = readTaskDocument(roots.reports, url.searchParams.get("id") || "");
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
