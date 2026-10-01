#!/usr/bin/env node
// fm-jsonl-viewer.mjs - token-protected, read-only browser viewer for the
// current Firstmate home's ShortTask journals, supervision branch sessions,
// and canonical task reports.
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
// below state/short-agents and state/branch-session and data/<task>/report.md
// files are eligible.

import { timingSafeEqual } from "node:crypto";
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

function safeReportFile(root, candidate) {
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
    const file = safeReportFile(root, join(directory, "report.md"));
    if (!file) continue;
    let info;
    try { info = lstatSync(file); } catch { continue; }
    if (!info.isFile() || info.isSymbolicLink()) continue;
    reports.push({ source: "report", id, label: id, bytes: info.size, modifiedAt: info.mtime.toISOString() });
  }
  return reports.sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt));
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
  return safeReportFile(root, join(directory, "report.md"));
}

function readReport(root, id) {
  const file = resolveReport(root, id);
  if (!file) return { status: 404, body: { error: "unknown or disallowed report" } };
  let opened;
  try { opened = openVerified(file, root); }
  catch (error) { return { status: 409, body: { error: error.message } }; }
  try {
    if (opened.info.size > MAX_REPORT_BYTES) {
      return { status: 413, body: { error: "report exceeds the 8 MiB display limit" } };
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
      return { status: 409, body: { error: "selected report changed during read" } };
    }
    return {
      status: 200,
      body: {
        source: "report",
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
  const assetRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../web/jsonl-viewer");
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
    if (url.pathname === "/api/events") {
      const result = readEvents(roots, url.searchParams.get("source") || "", url.searchParams.get("id") || "", url.searchParams);
      return json(res, result.status, result.body);
    }
    if (url.pathname === "/api/report") {
      const result = readReport(roots.reports, url.searchParams.get("id") || "");
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

serve();
