#!/usr/bin/env node
// Publish and browse durable Firstmate completion reports.
//
// The report stack is machine-global and independent of FM_HOME and provider
// account homes. New tasks record report_required=1; teardown first quiesces the
// endpoint, then publishes before account release or worktree removal.
// Publication is idempotent by canonical Firstmate home + task id, serialized,
// staged, and swapped into place only after every artifact is ready.
//
// Usage: fm-report-stack.mjs publish <task-id> [--legacy]
//        fm-report-stack.mjs render
//        fm-report-stack.mjs list [--json]
//        fm-report-stack.mjs path [<task-id>]
//        fm-report-stack.mjs open [<task-id>]
//        fm-report-stack.mjs prune
//
// FM_REPORT_STACK_ROOT overrides the default. When XDG_DATA_HOME is set, the
// default is $XDG_DATA_HOME/firstmate/report-stack; otherwise it is
// ~/.local/share/firstmate/report-stack. FM_HOME, FM_STATE_OVERRIDE, and
// FM_DATA_OVERRIDE select the task source like the rest of Firstmate.
// FM_REPORT_LOCK_WAIT_MS may extend lock contention waits from the 60-second
// default up to 15 minutes for explicit conservative maintenance flows.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import markdownModule from "./fm-markdown-structure.cjs";

const command = process.argv[2] || "list";
const args = process.argv.slice(3);
const fmRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fmHome = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot);
const stateDir = path.resolve(process.env.FM_STATE_OVERRIDE || path.join(fmHome, "state"));
const dataDir = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(fmHome, "data"));
const configuredStackRoot = path.resolve(process.env.FM_REPORT_STACK_ROOT || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "firstmate", "report-stack"));
let stackRoot = configuredStackRoot;
let entriesDir = path.join(stackRoot, "entries");
let stackRootDescriptor;
let entriesDescriptor;
let retentionTombstoneDescriptor;
const requiredSections = ["Summary", "What changed", "Verification", "Visual evidence", "Artifacts", "Follow-ups"];
const informationalTrailLimit = 4 * 1024 * 1024;
const completionReportLimit = 16 * 1024 * 1024;
const metadataLimit = 1024 * 1024;
const manifestLimit = 1024 * 1024;
const transactionLimit = 64 * 1024;
const lockControlLimit = 4 * 1024;
const configuredReportLockWaitMs = Number.parseInt(process.env.FM_REPORT_LOCK_WAIT_MS || "60000", 10);
const reportLockWaitMs = Number.isSafeInteger(configuredReportLockWaitMs)
  && configuredReportLockWaitMs >= 1_000
  && configuredReportLockWaitMs <= 900_000
  ? configuredReportLockWaitMs
  : 60_000;
const reportLockStaleMs = 60_000;
const visualEntryLimit = 512;
const visualDepthLimit = 24;
const visualBytesLimit = 20 * 1024 * 1024;
const visualInventoryLimit = visualEntryLimit * visualDepthLimit * 255 * 6 + visualEntryLimit * 32 + 1024;
const reportRetentionMs = 30 * 24 * 60 * 60 * 1000;
const reportRetentionDriftMs = 15 * 24 * 60 * 60 * 1000;
const reportRetentionBatch = Number.parseInt(process.env.FM_REPORT_RETENTION_BATCH || "4", 10);
const reportRetentionCohortMs = Number(process.env.FM_REPORT_RETENTION_COHORT_MS || String(5 * 60 * 1000));
const reportRetentionSweepSeconds = Number(process.env.FM_REPORT_RETENTION_INTERVAL || "300");
const reportRetentionSweepMs = reportRetentionSweepSeconds * 1000;
const retentionPolicyName = ".retention-policy.js";
const containedReadHelper = path.join(fmRoot, "bin", "fm-contained-read.py");
const pythonRuntime = process.env.FM_REPORT_PYTHON || "python3";

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function gitCommonDirectory(checkout) {
  try {
    const raw = execFileSync("git", ["-C", checkout, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!raw) return "";
    return fs.realpathSync(path.isAbsolute(raw) ? raw : path.resolve(checkout, raw));
  } catch {
    return "";
  }
}

function refuseIfGateAgent() {
  if (process.env.FM_GATE_REFUSE_BYPASS === "1") return;
  if (Object.prototype.hasOwnProperty.call(process.env, "NO_MISTAKES_GATE")) {
    console.error("error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)");
    process.exit(3);
  }
  for (const checkout of [process.cwd(), fmRoot]) {
    const common = gitCommonDirectory(checkout);
    if (/(?:^|[\\/])\.no-mistakes[\\/]repos[\\/][^\\/]+\.git$/.test(common)) {
      console.error(`error: refusing fleet lifecycle from inside a no-mistakes gate worktree (${common})`);
      process.exit(3);
    }
  }
}

function parseMeta(content) {
  const result = {};
  for (const line of content.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) result[line.slice(0, index)] = line.slice(index + 1);
  }
  return result;
}

function stableReportId(taskId) {
  const scope = fs.realpathSync(fmHome);
  const digest = crypto.createHash("sha256").update(`${scope}\0${taskId}`).digest("hex").slice(0, 12);
  return `${taskId}-${digest}`;
}

function titleFromBrief(taskId, brief) {
  const match = brief.match(/^# Task\s*\n+([\s\S]*?)(?=\n# |\n\*\*|$)/m);
  const candidate = match?.[1]?.trim().replace(/\s+/g, " ");
  return candidate && candidate !== "{TASK}" ? candidate.slice(0, 160) : taskId;
}

function lastStatus(status) {
  const lines = status.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines[lines.length - 1] || "Completed task";
}

const { markdownStructure } = markdownModule;

function firstSummary(markdown, fallback) {
  const structure = markdownStructure(markdown);
  const summaryStart = structure.findIndex(({ heading }) => heading?.level === 2 && heading.content.toLowerCase() === "summary");
  let summaryLines;
  if (summaryStart >= 0) {
    const followingHeading = structure.findIndex(({ heading }, index) => index > summaryStart && heading?.level === 2);
    summaryLines = structure.slice(summaryStart + 1, followingHeading < 0 ? undefined : followingHeading).map(({ line }) => line);
  } else {
    summaryLines = structure.map(({ line }) => line);
  }
  const text = summaryLines.join("\n")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`>#-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return (text || fallback).slice(0, 320);
}

function requireCompletionSections(markdown, sourceFile, taskId) {
  const sections = new Map(requiredSections.map((section) => [section.toLowerCase(), { present: false, body: [] }]));
  let currentSection;
  for (const entry of markdownStructure(markdown, { includeFenceContent: true })) {
    if (entry.heading?.level === 2) {
      currentSection = sections.get(entry.heading.content.toLowerCase());
      if (currentSection) currentSection.present = true;
    } else if (currentSection) {
      currentSection.body.push(entry);
    }
  }
  const substantive = ({ line, heading, fenced }) => {
    if (heading) return false;
    if (fenced) return /[\p{L}\p{N}\p{S}\p{P}]/u.test(line);
    const text = line
      .replace(/!\[([^\]]*)\]\(([^)]*)\)/g, "$1 $2")
      .replace(/\[([^\]]*)\]\(([^)]*)\)/g, "$1 $2")
      .replace(/<[^>]*>/g, " ")
      .replace(/[`*_~#|]/g, " ");
    return /[\p{L}\p{N}\p{S}]/u.test(text);
  };
  const missing = requiredSections.filter((section) => !sections.get(section.toLowerCase()).present);
  const empty = requiredSections.filter((section) => {
    const state = sections.get(section.toLowerCase());
    return state.present && !state.body.some(substantive);
  });
  if (missing.length === 0 && empty.length === 0) return;
  const required = requiredSections.map((section) => `## ${section}`).join(", ");
  const absent = missing.map((section) => `## ${section}`).join(", ");
  const blank = empty.map((section) => `## ${section}`).join(", ");
  const problems = [];
  if (missing.length > 0) problems.push(`missing required section headings: ${absent}`);
  if (empty.length > 0) problems.push(`required sections have no substantive content: ${blank}`);
  throw new Error(
    `completion report at ${sourceFile} ${problems.join("; ")}. `
    + `Update ${sourceFile} to include these level-two headings with substantive content: ${required}. `
    + `Then rerun ${fmRoot}/bin/fm-report-stack.mjs publish ${taskId} or ${fmRoot}/bin/fm-teardown.sh ${taskId}. `
    + "This attempt did not replace the durable report, and teardown remains stopped before destructive cleanup.",
  );
}

function gitValue(worktree, gitArgs) {
  if (!worktree || !fs.existsSync(worktree)) return "";
  try {
    return execFileSync("git", ["-C", worktree, ...gitArgs], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

function displaySha(value) {
  const sha = String(value || "").trim();
  return /^[0-9a-f]{7,64}$/i.test(sha) ? sha.toLowerCase().slice(0, 12) : "";
}

function processStartIdentity(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return "";
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
      stdio: ["ignore", "pipe", "ignore"],
    }).trim().replace(/\s+/g, " ");
  } catch {
    return "";
  }
}

function isContained(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

function realDirectory(directory, root, label) {
  let stat;
  try {
    stat = fs.lstatSync(directory);
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`${label} is missing at ${directory}`);
    throw error;
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory at ${directory}`);
  const real = fs.realpathSync(directory);
  if (root && !isContained(root, real)) throw new Error(`${label} escapes its configured root at ${directory}`);
  return real;
}

function pinnedDirectory(directory, root, label) {
  const initial = fs.lstatSync(directory);
  if (initial.isSymbolicLink() || !initial.isDirectory()) throw new Error(`${label} must be a real directory at ${directory}`);
  const descriptor = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isDirectory() || opened.dev !== initial.dev || opened.ino !== initial.ino) {
      throw new Error(`${label} changed while opening ${directory}`);
    }
    const real = fs.realpathSync(directory);
    if (root && !isContained(root, real)) throw new Error(`${label} escapes its configured root at ${directory}`);
    const current = fs.lstatSync(directory);
    if (current.isSymbolicLink() || !current.isDirectory()
      || current.dev !== opened.dev || current.ino !== opened.ino) {
      throw new Error(`${label} changed while opening ${directory}`);
    }
    return { path: directory, real, dev: opened.dev, ino: opened.ino, descriptor, label };
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

function inspectPinnedDirectory(directory) {
  const stat = fs.lstatSync(directory.path);
  const opened = fs.fstatSync(directory.descriptor);
  if (!opened.isDirectory() || opened.dev !== directory.dev || opened.ino !== directory.ino
    || stat.isSymbolicLink() || !stat.isDirectory()
    || stat.dev !== directory.dev || stat.ino !== directory.ino
    || fs.realpathSync(directory.path) !== directory.real) {
    throw new Error(`${directory.label} changed while reading ${directory.path}`);
  }
  return directory.real;
}

function sameDirectoryIdentity(descriptor, directory = ".") {
  const opened = fs.fstatSync(descriptor);
  const current = fs.statSync(directory);
  return opened.isDirectory() && current.isDirectory()
    && opened.dev === current.dev && opened.ino === current.ino;
}

function framedItems(buffer) {
  const newline = buffer.indexOf(10);
  if (newline < 0) throw new Error("contained reader returned an invalid response");
  const header = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
  let offset = newline + 1;
  const result = new Map();
  for (const item of header.items || []) {
    const length = Number(item.bytes || 0);
    if (!Number.isSafeInteger(length) || length < 0 || offset + length > buffer.length) {
      throw new Error("contained reader returned an incomplete response");
    }
    result.set(item.name, { ...item, content: buffer.subarray(offset, offset + length) });
    offset += length;
  }
  if (offset !== buffer.length) throw new Error("contained reader returned trailing data");
  return result;
}

function runContainedHelper(arguments_, descriptors, maxBuffer) {
  try {
    return execFileSync(pythonRuntime, [containedReadHelper, ...arguments_], {
      encoding: null,
      maxBuffer,
      stdio: ["ignore", "pipe", "pipe", ...descriptors],
    });
  } catch (error) {
    const detail = error.stderr?.toString("utf8").trim().replace(/^error:\s*/, "");
    throw new Error(detail || error.message);
  }
}

function readArtifact(file, root, label, options = {}) {
  inspectPinnedDirectory(root);
  const relative = path.relative(root.path, file);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its configured root at ${file}`);
  }
  const mode = options.truncate || "strict";
  let buffer;
  try {
    buffer = runContainedHelper(
      ["read-fd", relative, String(options.maxBytes), mode],
      [root.descriptor],
      options.maxBytes + 1024 * 1024,
    );
  } catch (error) {
    if (error.message.includes(`source is a symlink: ${relative}`)) {
      throw new Error(`${label} must be a real regular file at ${file}`);
    }
    throw error;
  }
  const source = framedItems(buffer).get("source");
  if (!source || source.missing) return undefined;
  if (source.oversized && !options.truncate) {
    if (options.overflowMessage) throw new Error(options.overflowMessage(source.size));
    throw new Error(`${label} exceeds its ${options.maxBytes}-byte limit at ${file}`);
  }
  const content = source.content.toString("utf8");
  if (!source.oversized) return content;
  const kept = options.truncate === "tail" ? "last" : "first";
  const marker = `[${label} truncated: original size ${source.size} bytes; kept ${kept} ${source.bytes} bytes]`;
  return options.truncate === "tail" ? `${marker}\n${content}` : `${content}\n${marker}\n`;
}

function readDescriptorAtMost(descriptor, maxBytes, overflowMessage) {
  const buffer = Buffer.alloc(maxBytes + 1);
  let bytesRead = 0;
  while (bytesRead < buffer.length) {
    const count = fs.readSync(descriptor, buffer, bytesRead, buffer.length - bytesRead, null);
    if (count === 0) break;
    bytesRead += count;
  }
  if (bytesRead > maxBytes) {
    throw new Error(overflowMessage(bytesRead));
  }
  return buffer.subarray(0, bytesRead);
}

function readBoundedRegularFile(file, maxBytes, label) {
  const initial = fs.lstatSync(file);
  if (initial.isSymbolicLink() || !initial.isFile()) throw new Error(`${label} must be a real regular file at ${file}`);
  if (process.env.FM_REPORT_BOUNDED_READ_TEST_READY && process.env.FM_REPORT_BOUNDED_READ_TEST_PROCEED) {
    fs.writeFileSync(process.env.FM_REPORT_BOUNDED_READ_TEST_READY, "ready\n", { flag: "wx" });
    const deadline = Date.now() + 5000;
    while (!fs.existsSync(process.env.FM_REPORT_BOUNDED_READ_TEST_PROCEED)) {
      if (Date.now() >= deadline) throw new Error("bounded report read test gate timed out");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
  const descriptor = fs.openSync(file, flags);
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.dev !== initial.dev || stat.ino !== initial.ino) {
      throw new Error(`${label} must be a stable real regular file at ${file}`);
    }
    if (stat.size > maxBytes) throw new Error(`${label} exceeds its ${maxBytes}-byte limit at ${file}`);
    return readDescriptorAtMost(
      descriptor,
      maxBytes,
      () => `${label} exceeds its ${maxBytes}-byte limit at ${file}`,
    ).toString("utf8");
  } finally {
    fs.closeSync(descriptor);
  }
}

function readLockControl(file, label) {
  return readBoundedRegularFile(file, lockControlLimit, label);
}

function reportLockControlOwner(file, label) {
  const owner = JSON.parse(readLockControl(file, label).trim());
  if (!Number.isInteger(owner.pid) || owner.pid <= 0 || typeof owner.startedAt !== "string"
    || !owner.startedAt || typeof owner.token !== "string" || !owner.token) {
    throw new Error(`invalid ${label} at ${file}`);
  }
  return owner;
}

function reportLockControlOwnerLiveness(owner) {
  try {
    process.kill(owner.pid, 0);
  } catch (error) {
    if (error.code === "ESRCH") return "dead";
    return "unknown";
  }
  const startedAt = processStartIdentity(owner.pid);
  if (!startedAt) return "unknown";
  return startedAt === owner.startedAt ? "live" : "dead";
}

function reportPublicationOwnerState(file, label, requireToken = false) {
  let observed;
  try {
    observed = fs.lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return { kind: "legacy-unowned", reason: "owner metadata is absent" };
    return { kind: "unknown", reason: error.message };
  }
  if (observed.isSymbolicLink() || !observed.isFile()) {
    return { kind: "legacy-unowned", reason: "owner metadata is not a regular file" };
  }
  if (observed.size > lockControlLimit) {
    return { kind: "legacy-unowned", reason: "owner metadata is oversized" };
  }
  let raw;
  try {
    raw = readLockControl(file, label).trim();
  } catch (error) {
    return { kind: "unknown", reason: error.message };
  }
  try {
    const owner = JSON.parse(raw);
    const identified = Number.isInteger(owner.pid) && owner.pid > 0
      && typeof owner.startedAt === "string" && owner.startedAt.length > 0;
    const tokenValid = typeof owner.token === "string" && owner.token.length > 0;
    if (identified && (!requireToken || tokenValid)) return { kind: "identified", owner };
  } catch {}
  return { kind: "legacy-unowned", reason: "owner metadata has no verifiable process generation" };
}

function reportPublicationOwnerLiveness(state) {
  if (state.kind !== "identified") return state.kind;
  return reportLockControlOwnerLiveness(state.owner);
}

function reportLockGenerationMtime(lockStat, ownerFile) {
  let staleMtimeMs = lockStat.mtimeMs;
  try {
    staleMtimeMs = Math.min(staleMtimeMs, fs.lstatSync(ownerFile).mtimeMs);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return staleMtimeMs;
}

function removeOwnedReportLockControl(file, token, label) {
  const owner = reportLockControlOwner(file, label);
  if (owner.token !== token) throw new Error(`${label} token changed`);
  const observed = fs.lstatSync(file);
  if (observed.isSymbolicLink() || !observed.isFile()) throw new Error(`${label} must be a real regular file at ${file}`);
  const pin = `${file}.pin.${process.pid}.${crypto.randomUUID()}`;
  fs.linkSync(file, pin);
  try {
    const pinned = fs.lstatSync(pin);
    const current = fs.lstatSync(file);
    const pinnedOwner = reportLockControlOwner(pin, `pinned ${label}`);
    if (pinned.dev !== observed.dev || pinned.ino !== observed.ino
      || current.dev !== observed.dev || current.ino !== observed.ino
      || pinnedOwner.token !== token) {
      throw new Error(`${label} generation changed before removal`);
    }
    runContainedHelper(
      ["remove-owned-file-fd", path.basename(file), `${observed.dev}:${observed.ino}`, `.${path.basename(file)}.removed.${crypto.randomUUID()}`],
      [stackRootDescriptor],
      1024 * 1024,
    );
  } finally {
    fs.rmSync(pin, { force: true });
  }
}

function recoverReportLockReclaimGuard(file) {
  let observed;
  try {
    observed = fs.lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return true;
    throw error;
  }
  if (observed.isSymbolicLink() || !observed.isFile()) {
    throw new Error(`report lock reclaim guard must be a real regular file at ${file}`);
  }
  const owner = reportLockControlOwner(file, "report lock reclaim guard");
  if (reportLockControlOwnerLiveness(owner) !== "dead") return false;
  removeOwnedReportLockControl(file, owner.token, "report lock reclaim guard");
  return true;
}

function tryAcquireReportLockReclaimGuard(file, token) {
  const candidate = `${file}.candidate.${process.pid}.${token}`;
  const startedAt = processStartIdentity(process.pid);
  if (!startedAt) throw new Error(`cannot identify report lock reclaimer ${process.pid}`);
  fs.writeFileSync(candidate, `${JSON.stringify({ pid: process.pid, startedAt, token })}\n`, { flag: "wx", mode: 0o600 });
  try {
    fs.linkSync(candidate, file);
    return true;
  } catch (error) {
    if (error.code === "EEXIST") return false;
    throw error;
  } finally {
    fs.rmSync(candidate, { force: true });
  }
}

const completedTestFifoHandshakes = new Set();

function runTestFifoHandshake(readyName, proceedName, payload, label) {
  const ready = process.env[readyName];
  const proceed = process.env[proceedName];
  if (!ready && !proceed) return;
  if (!ready || !proceed) throw new Error(`${label} requires both FIFO endpoints`);
  const handshake = `${readyName}\0${proceedName}`;
  if (completedTestFifoHandshakes.has(handshake)) return;
  for (const [file, endpoint] of [[ready, "ready"], [proceed, "proceed"]]) {
    const observed = fs.lstatSync(file);
    if (observed.isSymbolicLink() || !observed.isFIFO()) {
      throw new Error(`${label} ${endpoint} endpoint must be a real FIFO at ${file}`);
    }
  }
  const program = [
    "import os, select, sys, time",
    "ready = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)",
    "proceed = os.open(sys.argv[2], os.O_RDONLY | os.O_NONBLOCK)",
    "try:",
    "    os.write(ready, sys.argv[3].encode('utf-8'))",
    "    deadline = time.monotonic() + 10",
    "    permit = b''",
    "    while b'\\n' not in permit:",
    "        remaining = deadline - time.monotonic()",
    "        if remaining <= 0:",
    "            raise RuntimeError(sys.argv[4] + ' timed out')",
    "        readable, _, _ = select.select([proceed], [], [], remaining)",
    "        if not readable:",
    "            raise RuntimeError(sys.argv[4] + ' timed out')",
    "        chunk = os.read(proceed, 256)",
    "        if not chunk:",
    "            raise RuntimeError(sys.argv[4] + ' closed without a permit')",
    "        permit += chunk",
    "        if len(permit) > 256:",
    "            raise RuntimeError(sys.argv[4] + ' permit is oversized')",
    "    line, trailing = permit.split(b'\\n', 1)",
    "    if line != b'continue' or trailing:",
    "        raise RuntimeError(sys.argv[4] + ' received an invalid permit')",
    "finally:",
    "    os.close(ready)",
    "    os.close(proceed)",
  ].join("\n");
  try {
    execFileSync(pythonRuntime, ["-c", program, ready, proceed, payload, label], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 11_000,
    });
    completedTestFifoHandshakes.add(handshake);
  } catch (error) {
    const detail = error.stderr?.toString("utf8").trim();
    throw new Error(detail || `${label} failed`);
  }
}

function pathExistsNoFollow(file) {
  try {
    fs.lstatSync(file);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

function assertSafeFileDestination(file, label) {
  try {
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink() || !stat.isFile()) throw new Error(`${label} must be absent or a real regular file at ${file}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function escapeHtml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function safeHttpUrl(value) {
  if (!value) return "";
  try {
    const parsed = new URL(value);
    if (parsed.username || parsed.password) return "";
    parsed.search = "";
    parsed.hash = "";
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.href : "";
  } catch {
    return "";
  }
}

function relativeUrl(value) {
  return String(value).split("/").map((segment) => encodeURIComponent(segment)).join("/");
}

function sharedCss() {
  return `:root{color-scheme:light dark;--bg:#f4f1e8;--panel:#fffdf7;--ink:#1c2623;--muted:#68736f;--accent:#17745b;--line:#d8d7ce}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 ui-sans-serif,system-ui,-apple-system,sans-serif}main{max-width:1080px;margin:auto;padding:48px 24px 80px}nav{margin-bottom:36px}a{color:var(--accent)}header{max-width:820px;margin-bottom:28px}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:.75rem;color:var(--accent);font-weight:700}h1{font:700 clamp(2rem,6vw,4.5rem)/1.02 ui-serif,Georgia,serif;margin:.2em 0}h2{font:700 1.5rem/1.2 ui-serif,Georgia,serif;margin-top:2.2rem}dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}dl div,.card,pre.report,figure{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px}dt{font-size:.75rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}dd{margin:4px 0 0;overflow-wrap:anywhere}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.gallery img{width:100%;max-height:420px;object-fit:contain;border-radius:8px}.gallery figure{margin:0}.gallery figcaption{margin-top:8px;color:var(--muted);font-size:.85rem}pre.report{white-space:pre-wrap;overflow-wrap:anywhere;font:15px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}.muted,.meta{color:var(--muted)}.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin:28px 0}.toolbar input,.toolbar select{font:inherit;padding:12px 14px;border:1px solid var(--line);border-radius:10px;background:var(--panel);color:var(--ink)}.toolbar input{flex:1;min-width:240px}.cards{display:grid;gap:14px}.card h2{margin:.2rem 0 .35rem}.card p{margin:.35rem 0}.card a{text-decoration:none;color:inherit}.empty{padding:40px;text-align:center;color:var(--muted)}@media(prefers-color-scheme:dark){:root{--bg:#14201d;--panel:#1d2b27;--ink:#f4f1e8;--muted:#a9b5b0;--accent:#74d2b3;--line:#344640}}`;
}

function reportPage(manifest, markdown, visuals) {
  const worktreeHead = manifest.worktreeHead || manifest.commit || "";
  const revisionDetails = `${manifest.prHead ? `<div><dt>PR head</dt><dd>${escapeHtml(manifest.prHead)}</dd></div>` : ""}<div><dt>Worktree HEAD</dt><dd>${escapeHtml(worktreeHead || "not recorded")}</dd></div>`;
  const gallery = visuals.length
    ? `<section><h2>Visual evidence</h2><div class="gallery">${visuals.map((visual) => {
      const label = escapeHtml(path.basename(visual));
      const href = escapeHtml(relativeUrl(visual));
      return /\.(?:gif|jpe?g|png|svg|webp)$/i.test(visual)
        ? `<figure><a href="${href}"><img src="${href}" alt="${label}"></a><figcaption>${label}</figcaption></figure>`
        : `<figure><a href="${href}">${label}</a><figcaption>Visual artifact</figcaption></figure>`;
    }).join("")}</div></section>`
    : `<section><h2>Visual evidence</h2><p class="muted">No image artifacts were attached.</p></section>`;
  return `<!doctype html>
<html lang="en" style="visibility:hidden"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(manifest.title)} · Firstmate report</title><style>${sharedCss()}</style><script src="../../../${retentionPolicyName}"></script></head><body><main>
<nav><a href="../../../index.html">← Report stack</a></nav>
<header><p class="eyebrow">${escapeHtml(manifest.kind)} · ${escapeHtml(manifest.mode)}</p><h1>${escapeHtml(manifest.title)}</h1><p>${escapeHtml(manifest.summary)}</p></header>
<dl><div><dt>Task</dt><dd>${escapeHtml(manifest.taskId)}</dd></div><div><dt>Completed</dt><dd>${escapeHtml(manifest.completedAt)}</dd></div><div><dt>Project</dt><dd>${escapeHtml(manifest.project)}</dd></div><div><dt>Harness</dt><dd>${escapeHtml(manifest.harness)}</dd></div><div><dt>Account profile</dt><dd>${escapeHtml(manifest.accountProfile || "unmanaged")}</dd></div>${revisionDetails}</dl>
${gallery}
<section><h2>Completion report</h2><pre class="report">${escapeHtml(markdown)}</pre></section>
<section><h2>Trail</h2><p><a href="report.md">Report source</a> · <a href="brief.md">Task brief</a> · <a href="status.log">Status trail</a>${manifest.prUrl ? ` · <a href="${escapeHtml(manifest.prUrl)}">Pull request</a>` : ""}</p></section>
</main><script>(()=>{const cutoff=Number(window.firstmateRetentionPolicy?.cutoffMs);const completedAt=Date.parse(${JSON.stringify(manifest.completedAt)});if(Number.isFinite(cutoff)&&Number.isFinite(completedAt)&&completedAt<=cutoff){document.body.replaceChildren(Object.assign(document.createElement('main'),{textContent:'This report has expired.'}));}document.documentElement.style.visibility='visible';})();</script></body></html>`;
}

function indexPage(rows, policy) {
  const data = JSON.stringify(rows).replaceAll("<", "\\u003c");
  const authority = JSON.stringify({ schemaVersion: 1, generation: policy.generation, cutoffMs: policy.cutoffMs });
  return `<!-- firstmate-retention ${authority} -->
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Firstmate report stack</title><style>${sharedCss()}</style></head><body><main>
<header><p class="eyebrow">Firstmate completion ledger</p><h1>Report stack</h1><p>Durable, account-independent records of wrapped work.</p></header>
<div class="toolbar"><input id="search" type="search" placeholder="Search tasks, summaries, projects…"><select id="kind"><option value="">All task types</option><option value="ship">Ship</option><option value="scout">Scout</option></select></div><div id="cards" class="cards"></div>
<script src="${retentionPolicyName}"></script><script>const cutoff=Number(window.firstmateRetentionPolicy?.cutoffMs);const reports=${data}.filter(r=>!Number.isFinite(cutoff)||Date.parse(r.completedAt)>cutoff);const cards=document.querySelector('#cards');const search=document.querySelector('#search');const kind=document.querySelector('#kind');const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function draw(){const q=search.value.toLowerCase();const rows=reports.filter(r=>(!kind.value||r.kind===kind.value)&&(!q||[r.title,r.summary,r.taskId,r.project,r.harness,r.accountProfile].join(' ').toLowerCase().includes(q)));cards.innerHTML=rows.length?rows.map(r=>'<article class="card"><a href="entries/'+encodeURIComponent(r.retentionCohort)+'/'+encodeURIComponent(r.reportId)+'/report.html"><p class="eyebrow">'+esc(r.kind)+' · '+esc(r.completedAt.slice(0,10))+'</p><h2>'+esc(r.title)+'</h2><p>'+esc(r.summary)+'</p><p class="meta">'+esc(r.project)+' · '+esc(r.harness)+(r.accountProfile?' · '+esc(r.accountProfile):'')+'</p></a></article>').join(''):'<div class="empty">No matching reports.</div>'}search.addEventListener('input',draw);kind.addEventListener('change',draw);draw();</script>
</main></body></html>`;
}

function acquireLock() {
  fs.mkdirSync(configuredStackRoot, { recursive: true, mode: 0o700 });
  const pinnedStackRoot = pinnedDirectory(configuredStackRoot, undefined, "report stack root");
  process.chdir(configuredStackRoot);
  if (!sameDirectoryIdentity(pinnedStackRoot.descriptor)) {
    fs.closeSync(pinnedStackRoot.descriptor);
    throw new Error(`report stack root changed while entering ${configuredStackRoot}`);
  }
  stackRootDescriptor = pinnedStackRoot.descriptor;
  stackRoot = ".";
  const lock = path.join(stackRoot, ".publish.lock");
  const reclaimGuard = path.join(stackRoot, ".publish.lock.reclaim");
  let lockDeadline = Date.now() + reportLockWaitMs;
  let reclaimGuardWaiterSignaled = false;
  while (true) {
    const deadlineExpired = Date.now() >= lockDeadline;
    try {
      fs.lstatSync(reclaimGuard);
      if (!reclaimGuardWaiterSignaled) {
        runTestFifoHandshake(
          "FM_REPORT_RECLAIM_WAITER_TEST_READY",
          "FM_REPORT_RECLAIM_WAITER_TEST_PROCEED",
          "guard-observed\n",
          "report reclaim waiter test gate",
        );
        reclaimGuardWaiterSignaled = true;
      }
      if (recoverReportLockReclaimGuard(reclaimGuard)) {
        runTestFifoHandshake(
          "FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_READY",
          "FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_PROCEED",
          "guard-released\n",
          "report reclaim guard released test gate",
        );
        if (Date.now() >= lockDeadline) lockDeadline = Date.now() + 1_000;
        continue;
      }
      if (deadlineExpired) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
      continue;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (deadlineExpired) break;
    const token = crypto.randomUUID();
    const candidate = path.join(stackRoot, `.publish.lock.candidate.${process.pid}.${token}`);
    try {
      fs.mkdirSync(candidate, { mode: 0o700 });
      try {
        const startedAt = processStartIdentity(process.pid);
        if (!startedAt) throw new Error(`cannot identify report publisher process ${process.pid}`);
        fs.writeFileSync(path.join(candidate, "owner"), `${JSON.stringify({ pid: process.pid, startedAt, token })}\n`, { mode: 0o600 });
        let reclaimGuardExists = true;
        try { fs.lstatSync(reclaimGuard); } catch (error) { if (error.code === "ENOENT") reclaimGuardExists = false; else throw error; }
        if (!reclaimGuardExists) {
          runTestFifoHandshake(
            "FM_REPORT_LOCK_PRECHECK_TEST_READY",
            "FM_REPORT_LOCK_PRECHECK_TEST_PROCEED",
            "guard-absent\n",
            "report lock precheck test gate",
          );
        }
        const lockExists = pathExistsNoFollow(lock);
        if (reclaimGuardExists || lockExists) {
          fs.rmSync(candidate, { recursive: true, force: true });
          const existsError = new Error(`report lock exists at ${lock}`);
          existsError.code = "EEXIST";
          throw existsError;
        }
        const installGuardToken = crypto.randomUUID();
        if (!tryAcquireReportLockReclaimGuard(reclaimGuard, installGuardToken)) {
          recoverReportLockReclaimGuard(reclaimGuard);
          const existsError = new Error(`report lock reclaim guard exists at ${reclaimGuard}`);
          existsError.code = "EEXIST";
          throw existsError;
        }
        runTestFifoHandshake(
          "FM_REPORT_INSTALL_GUARD_TEST_READY",
          "FM_REPORT_INSTALL_GUARD_TEST_PROCEED",
          "install-guard-held\n",
          "report install guard test gate",
        );
        let installedLock = false;
        try {
          if (pathExistsNoFollow(lock)) {
            const existsError = new Error(`report lock exists at ${lock}`);
            existsError.code = "EEXIST";
            throw existsError;
          }
          fs.renameSync(candidate, lock);
          installedLock = true;
          runTestFifoHandshake(
            "FM_REPORT_LOCK_INSTALLED_GUARD_TEST_READY",
            "FM_REPORT_LOCK_INSTALLED_GUARD_TEST_PROCEED",
            "lock-installed-guard-held\n",
            "report installed-lock guard test gate",
          );
        } finally {
          try {
            if (installedLock && process.env.FM_REPORT_INSTALL_GUARD_RELEASE_TEST_FAILURE === "1") {
              throw new Error("synthetic report install-guard release failure");
            }
            removeOwnedReportLockControl(reclaimGuard, installGuardToken, "report lock reclaim guard");
          } catch (guardReleaseError) {
            if (installedLock) {
              try {
                runContainedHelper(
                  ["remove-owned-directory-fd", ".publish.lock", "owner", token],
                  [stackRootDescriptor],
                  1024 * 1024,
                );
              } catch (lockReleaseError) {
                throw new Error(
                  `report reclaim guard release failed (${guardReleaseError.message}); `
                  + `newly installed report lock release also failed (${lockReleaseError.message})`,
                );
              }
            }
            throw guardReleaseError;
          }
        }
      } catch (error) {
        fs.rmSync(candidate, { recursive: true, force: true });
        throw error;
      }
      const release = () => {
        if (process.env.FM_REPORT_LOCK_TEST_RELEASE_FAILURE === "1") {
          throw new Error("synthetic report publication lock release failure");
        }
        runContainedHelper(
          ["remove-owned-directory-fd", ".publish.lock", "owner", token],
          [stackRootDescriptor],
          1024 * 1024,
        );
      };
      let pinnedEntries;
      let pinnedTombstones;
      try {
        runTestFifoHandshake(
          "FM_REPORT_LOCK_ACQUIRED_TEST_READY",
          "FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED",
          "lock-acquired\n",
          "report lock acquired test gate",
        );
        runTestFifoHandshake(
          "FM_REPORT_LOCK_TEST_READY",
          "FM_REPORT_LOCK_TEST_PROCEED",
          "lock-acquired\n",
          "report lock test gate",
        );
        if (process.env.FM_REPORT_LOCK_TEST_SETUP_FAILURE === "1") {
          throw new Error("synthetic report publication lock setup failure");
        }
        entriesDir = "entries";
        try {
          fs.mkdirSync(entriesDir, { mode: 0o700 });
        } catch (error) {
          if (error.code !== "EEXIST") throw error;
        }
        pinnedEntries = pinnedDirectory(entriesDir, pinnedStackRoot.real, "report entries directory");
        try {
          fs.mkdirSync(".retention-tombstones", { mode: 0o700 });
        } catch (error) {
          if (error.code !== "EEXIST") throw error;
        }
        pinnedTombstones = pinnedDirectory(".retention-tombstones", pinnedStackRoot.real, "report retention tombstone directory");
        process.chdir(entriesDir);
        if (!sameDirectoryIdentity(pinnedEntries.descriptor)) {
          throw new Error("report entries directory changed while entering it");
        }
        entriesDir = ".";
        entriesDescriptor = pinnedEntries.descriptor;
        retentionTombstoneDescriptor = pinnedTombstones.descriptor;
        runTestFifoHandshake(
          "FM_REPORT_STACK_DESTINATION_TEST_READY",
          "FM_REPORT_STACK_DESTINATION_TEST_PROCEED",
          "destination-pinned\n",
          "report destination test gate",
        );
        return release;
      } catch (setupError) {
        try { fs.closeSync(pinnedEntries?.descriptor); } catch {}
        try { fs.closeSync(pinnedTombstones?.descriptor); } catch {}
        entriesDescriptor = undefined;
        retentionTombstoneDescriptor = undefined;
        try {
          release();
        } catch (releaseError) {
          console.error(`warning: report publication lock release also failed: ${releaseError.message}`);
        }
        try { fs.closeSync(stackRootDescriptor); } catch {}
        stackRootDescriptor = undefined;
        throw setupError;
      }
    } catch (error) {
      if (error.code !== "EEXIST" && error.code !== "ENOTEMPTY") throw error;
      runTestFifoHandshake(
        "FM_REPORT_LOCK_WAITER_TEST_READY",
        "FM_REPORT_LOCK_WAITER_TEST_PROCEED",
        "lock-observed\n",
        "report lock waiter test gate",
      );
      try {
        const lockStat = fs.lstatSync(lock);
        if (lockStat.isSymbolicLink() || !lockStat.isDirectory()) {
          throw new Error(`report lock must be a real directory at ${lock}`);
        }
        const ownerFile = path.join(lock, "owner");
        const ownerState = reportPublicationOwnerState(ownerFile, "report lock owner");
        const ownerLiveness = reportPublicationOwnerLiveness(ownerState);
        const staleMtimeMs = reportLockGenerationMtime(lockStat, ownerFile);
        const ownerReclaimable = ownerLiveness === "dead"
          || (ownerLiveness === "legacy-unowned" && Date.now() - staleMtimeMs > reportLockStaleMs);
        if (ownerReclaimable) {
          const reclaimGuardToken = crypto.randomUUID();
          if (!tryAcquireReportLockReclaimGuard(reclaimGuard, reclaimGuardToken)) {
            recoverReportLockReclaimGuard(reclaimGuard);
            continue;
          }
          try {
            const guardedLockStat = fs.lstatSync(lock);
            if (guardedLockStat.isSymbolicLink() || !guardedLockStat.isDirectory()) {
              throw new Error(`report lock must be a real directory at ${lock}`);
            }
            const guardedOwnerFile = path.join(lock, "owner");
            const guardedOwnerState = reportPublicationOwnerState(guardedOwnerFile, "report lock owner");
            const guardedOwnerLiveness = reportPublicationOwnerLiveness(guardedOwnerState);
            const guardedStaleMtimeMs = reportLockGenerationMtime(guardedLockStat, guardedOwnerFile);
            const guardedOwnerReclaimable = guardedOwnerLiveness === "dead"
              || (guardedOwnerLiveness === "legacy-unowned"
                && Date.now() - guardedStaleMtimeMs > reportLockStaleMs);
            if (!guardedOwnerReclaimable) continue;
            const reclaim = path.join(lock, ".reclaim");
            const reclaimToken = crypto.randomUUID();
            let claimed = false;
            try {
              const reclaimStartedAt = processStartIdentity(process.pid);
              if (!reclaimStartedAt) throw new Error(`cannot identify report lock reclaimer ${process.pid}`);
              const reclaimOwner = { pid: process.pid, startedAt: reclaimStartedAt, token: reclaimToken };
              fs.writeFileSync(reclaim, `${JSON.stringify(reclaimOwner)}\n`, { flag: "wx", mode: 0o600 });
              claimed = true;
              const claimedStat = fs.lstatSync(lock);
              if (claimedStat.dev !== guardedLockStat.dev || claimedStat.ino !== guardedLockStat.ino) {
                fs.rmSync(reclaim, { force: true });
                claimed = false;
                continue;
              }
              const quarantine = path.join(stackRoot, `.publish.lock.stale.${process.pid}.${reclaimToken}`);
              fs.renameSync(lock, quarantine);
              const quarantinedReclaim = JSON.parse(readLockControl(path.join(quarantine, ".reclaim"), "report reclaim marker"));
              if (quarantinedReclaim.token !== reclaimToken) {
                throw new Error(`report lock changed while reclaiming ${lock}`);
              }
              fs.rmSync(quarantine, { recursive: true, force: true });
              runTestFifoHandshake(
                "FM_REPORT_RECLAIM_TEST_READY",
                "FM_REPORT_RECLAIM_TEST_PROCEED",
                "lock-quarantined\n",
                "report reclaim test gate",
              );
              continue;
            } catch (reclaimError) {
              if (reclaimError.code === "EEXIST") {
                try {
                  const reclaimStat = fs.lstatSync(reclaim);
                  const reclaimState = reportPublicationOwnerState(
                    reclaim,
                    "report reclaim marker",
                    true,
                  );
                  const reclaimLiveness = reportPublicationOwnerLiveness(reclaimState);
                  const reclaimOwnerReclaimable = reclaimLiveness === "dead"
                    || reclaimLiveness === "legacy-unowned";
                  const currentLockStat = fs.lstatSync(lock);
                  if (reclaimOwnerReclaimable && Date.now() - reclaimStat.mtimeMs > reportLockStaleMs
                    && currentLockStat.dev === guardedLockStat.dev && currentLockStat.ino === guardedLockStat.ino) {
                    const quarantine = path.join(lock, `.reclaim.abandoned.${process.pid}.${crypto.randomUUID()}`);
                    fs.renameSync(reclaim, quarantine);
                    const quarantinedReclaimStat = fs.lstatSync(quarantine);
                    const expectedToken = reclaimState.kind === "identified" ? reclaimState.owner.token : "";
                    let quarantinedToken = "";
                    if (expectedToken) {
                      const quarantinedState = reportPublicationOwnerState(
                        quarantine,
                        "quarantined report reclaim marker",
                        true,
                      );
                      if (quarantinedState.kind === "identified") quarantinedToken = quarantinedState.owner.token;
                    }
                    if (quarantinedReclaimStat.dev !== reclaimStat.dev || quarantinedReclaimStat.ino !== reclaimStat.ino
                      || (expectedToken && quarantinedToken !== expectedToken)) {
                      if (!pathExistsNoFollow(reclaim)) fs.renameSync(quarantine, reclaim);
                      throw new Error(`report reclaim ownership changed while recovering ${lock}`);
                    }
                    fs.rmSync(quarantine, { recursive: true, force: true });
                  }
                } catch (reclaimOwnerError) {
                  if (reclaimOwnerError.code !== "ENOENT") throw reclaimOwnerError;
                }
              } else if (reclaimError.code !== "ENOENT") {
                throw reclaimError;
              }
            } finally {
              if (claimed) {
                try {
                  const reclaimOwner = JSON.parse(readLockControl(reclaim, "report reclaim marker"));
                  if (reclaimOwner.token === reclaimToken) fs.rmSync(reclaim, { force: true });
                } catch {}
              }
            }
          } finally {
            removeOwnedReportLockControl(reclaimGuard, reclaimGuardToken, "report lock reclaim guard");
          }
        }
      } catch (statError) {
        if (statError.code !== "ENOENT") throw statError;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
  throw new Error(`report stack is busy at ${lock}`);
}

let lastPruneStatus = { pruned: 0, pending: false };

function withLock(callback) {
  const release = acquireLock();
  let operationError;
  try {
    recoverRetentionCutover();
    const retentionPolicy = nextRetentionPolicy();
    recoverPreviousEntries();
    cutoverLegacyEntries();
    if (readStackControl(legacyCutoverName) !== undefined) {
      lastPruneStatus = { pruned: 0, pending: true };
      if (command === "prune") return callback();
      throw new Error("legacy report migration is pending; rerun retention");
    }
    expireDueCohorts(retentionPolicy);
    renderIndex(readRetentionPolicy());
    lastPruneStatus = pruneExpiredEntries();
    return callback();
  } catch (error) {
    operationError = error;
    throw error;
  } finally {
    try {
      release();
    } catch (releaseError) {
      if (!operationError) throw releaseError;
      console.error(`warning: report publication lock release also failed: ${releaseError.message}`);
    } finally {
      try { fs.closeSync(entriesDescriptor); } catch {}
      try { fs.closeSync(retentionTombstoneDescriptor); } catch {}
      try { fs.closeSync(stackRootDescriptor); } catch {}
      entriesDescriptor = undefined;
      retentionTombstoneDescriptor = undefined;
      stackRootDescriptor = undefined;
    }
  }
}

function snapshotTaskArtifacts(dataRoot, taskId, sourceName, staged, sourceFile) {
  const stagedDescriptor = fs.openSync(staged, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | (fs.constants.O_NOFOLLOW || 0));
  try {
    let buffer;
    try {
      buffer = runContainedHelper([
        "snapshot-task-fd",
        taskId,
        sourceName,
        String(informationalTrailLimit),
        String(completionReportLimit),
        String(visualBytesLimit),
        `${visualEntryLimit}:${visualDepthLimit}`,
      ], [dataRoot.descriptor, stagedDescriptor], informationalTrailLimit + completionReportLimit + 1024 * 1024);
    } catch (error) {
      if (error.message.includes(`source is a symlink: ${sourceName}`)) {
        throw new Error(`completion report must be a real regular file at ${sourceFile}`);
      }
      if (error.message.includes("source is a symlink: brief.md")) {
        throw new Error(`task brief must be a real regular file at ${path.join(dataDir, taskId, "brief.md")}`);
      }
      if (error.message.includes(`source is a symlink: ${taskId}`)) {
        throw new Error(`task data directory must be a real directory at ${path.join(dataDir, taskId)}`);
      }
      throw error;
    }
    const items = framedItems(buffer);
    const briefItem = items.get("brief");
    const sourceItem = items.get("source");
    if (sourceItem?.oversized) {
      throw new Error(`completion report at ${sourceFile} is ${sourceItem.size} bytes and exceeds the ${completionReportLimit}-byte publication limit. `
        + `Reduce ${sourceFile}, keeping every required section intact. `
        + `Then rerun ${fmRoot}/bin/fm-report-stack.mjs publish ${taskId} or ${fmRoot}/bin/fm-teardown.sh ${taskId}. `
        + "This attempt did not replace the durable report, and teardown remains stopped before destructive cleanup.");
    }
    const inventoryFile = path.join(staged, ".visuals.json");
    const visuals = JSON.parse(readBoundedRegularFile(inventoryFile, visualInventoryLimit, "visual inventory"));
    fs.rmSync(inventoryFile, { force: true });
    return {
      brief: briefItem && !briefItem.missing ? briefItem.content.toString("utf8") : "",
      source: sourceItem && !sourceItem.missing ? sourceItem.content.toString("utf8") : undefined,
      briefPresent: Boolean(briefItem && !briefItem.missing),
      sourcePresent: Boolean(sourceItem && !sourceItem.missing),
      visuals,
    };
  } finally {
    fs.closeSync(stagedDescriptor);
  }
}

function snapshotStateArtifact(stateRoot, file, staged, destinationName, viewLimit, mode, label) {
  inspectPinnedDirectory(stateRoot);
  const relative = path.relative(stateRoot.path, file);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its configured root at ${file}`);
  }
  const stagedDescriptor = fs.openSync(staged, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | (fs.constants.O_NOFOLLOW || 0));
  try {
    let buffer;
    try {
      buffer = runContainedHelper(
        ["snapshot-file-fd", relative, String(viewLimit), mode, destinationName],
        [stateRoot.descriptor, stagedDescriptor],
        viewLimit + 1024 * 1024,
      );
    } catch (error) {
      if (error.message.includes(`source is a symlink: ${path.basename(relative)}`)) {
        throw new Error(`${label} must be a real regular file at ${file}`);
      }
      throw error;
    }
    const source = framedItems(buffer).get("source");
    return source && !source.missing ? { present: true, view: source.content.toString("utf8") } : { present: false, view: "" };
  } finally {
    fs.closeSync(stagedDescriptor);
  }
}

function retentionCohortFor(completedAt) {
  const timestamp = Date.parse(completedAt);
  if (!Number.isFinite(timestamp)) throw new Error(`invalid report completion time: ${completedAt}`);
  const deadline = Math.ceil((timestamp + reportRetentionMs) / reportRetentionCohortMs) * reportRetentionCohortMs;
  return `cohort-${deadline}`;
}

function retentionCohortDeadline(name) {
  const match = name.match(/^cohort-([0-9]+)$/);
  if (!match) return Number.NaN;
  const deadline = Number(match[1]);
  return Number.isSafeInteger(deadline) ? deadline : Number.NaN;
}

function readEntryManifestAt(root, entryName) {
  const raw = runContainedHelper(
    ["cat-child-fd", entryName, "manifest.json", String(manifestLimit)],
    [root.descriptor],
    manifestLimit + 1024 * 1024,
  );
  return JSON.parse(raw.toString("utf8"));
}

function currentEntriesRoot() {
  const stat = fs.fstatSync(entriesDescriptor);
  return {
    path: path.resolve(entriesDir),
    real: fs.realpathSync(entriesDir),
    dev: stat.dev,
    ino: stat.ino,
    descriptor: entriesDescriptor,
  };
}

function readEntryManifest(cohortName, entryName) {
  const entriesRoot = currentEntriesRoot();
  const cohort = pinnedDirectory(path.join(entriesRoot.path, cohortName), entriesRoot.real, "report retention cohort");
  try {
    return readEntryManifestAt(cohort, entryName);
  } finally {
    fs.closeSync(cohort.descriptor);
  }
}

function readManifests(policy = readRetentionPolicy()) {
  if (!fs.existsSync(entriesDir)) return [];
  const manifests = [];
  for (const cohort of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    if (!cohort.isDirectory() || cohort.name.startsWith(".")) continue;
    const cohortDeadline = retentionCohortDeadline(cohort.name);
    if (!Number.isFinite(cohortDeadline)) {
      throw new Error(`invalid report retention cohort at ${path.join(entriesDir, cohort.name)}`);
    }
    for (const entry of fs.readdirSync(path.join(entriesDir, cohort.name), { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(entry.name)) {
        throw new Error(`invalid report entry id at ${path.join(entriesDir, cohort.name, entry.name)}`);
      }
      const file = path.join(entriesDir, cohort.name, entry.name, "manifest.json");
      const manifest = readEntryManifest(cohort.name, entry.name);
      if (!manifest) continue;
      const completedAt = Date.parse(manifest.completedAt);
      if (manifest.reportId !== entry.name
        || (manifest.retentionCohort !== undefined && manifest.retentionCohort !== cohort.name)
        || !Number.isFinite(completedAt)
        || cohortDeadline < completedAt + reportRetentionMs
        || cohortDeadline > completedAt + reportRetentionMs + reportRetentionDriftMs) {
        throw new Error(`report manifest identity mismatch at ${file}`);
      }
      if (Number.isFinite(policy.cutoffMs) && completedAt <= policy.cutoffMs) continue;
      manifests.push({ ...manifest, retentionCohort: cohort.name });
    }
  }
  return manifests.sort((a, b) => b.completedAt.localeCompare(a.completedAt));
}

function findReportEntry(reportId) {
  const matches = [];
  for (const cohort of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    if (!cohort.isDirectory() || !Number.isFinite(retentionCohortDeadline(cohort.name))) continue;
    const candidate = path.join(entriesDir, cohort.name, reportId);
    if (fs.existsSync(candidate)) matches.push({ cohort: cohort.name, path: candidate });
  }
  if (matches.length > 1) throw new Error(`report entry appears in multiple retention cohorts: ${reportId}`);
  return matches[0];
}

function readStackControl(name, maximum = transactionLimit) {
  const framed = runContainedHelper(["read-fd", name, String(maximum), "strict"], [stackRootDescriptor], maximum + 1024 * 1024);
  const item = framedItems(framed).get("source");
  return !item || item.missing ? undefined : item.content.toString("utf8");
}

function publishStackControl(name, value) {
  const tempName = `.${name}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(path.join(entriesDir, tempName), `${JSON.stringify(value)}\n`, { flag: "wx", mode: 0o600 });
  try {
    runContainedHelper(["replace-file-fd", tempName, name], [entriesDescriptor, stackRootDescriptor], 1024 * 1024);
  } finally {
    fs.rmSync(path.join(entriesDir, tempName), { force: true });
  }
}

function removeStackControl(name) {
  const file = path.join(configuredStackRoot, name);
  const stat = fs.lstatSync(file);
  runContainedHelper(
    ["remove-owned-file-fd", name, `${stat.dev}:${stat.ino}`, `.${name}.removed.${crypto.randomUUID()}`],
    [stackRootDescriptor],
    1024 * 1024,
  );
}

function moveStackDirectoryToPrivate(name, identity, tombstoneName = `tombstone-${crypto.randomUUID()}`) {
  runContainedHelper(
    ["rename-noreplace-owned-fd", name, tombstoneName, identity],
    [stackRootDescriptor, retentionTombstoneDescriptor],
    1024 * 1024,
  );
}

function moveEntryCohortToPrivate(name, identity) {
  runContainedHelper(
    ["rename-noreplace-owned-fd", name, `tombstone-${crypto.randomUUID()}`, identity],
    [entriesDescriptor, retentionTombstoneDescriptor],
    1024 * 1024,
  );
}

const legacyCutoverName = ".legacy-cutover.json";

function recoverLegacyCutover() {
  const raw = readStackControl(legacyCutoverName);
  if (raw === undefined) return;
  const record = JSON.parse(raw);
  if (record.schemaVersion !== 1 || !/^\.entries\.cutover\.[0-9a-f-]+$/.test(record.preparedName)
    || !/^\d+:\d+$/.test(record.oldIdentity) || !/^\d+:\d+$/.test(record.replacementIdentity)) {
    throw new Error(`invalid legacy report cutover marker at ${legacyCutoverName}`);
  }
  let current = fs.fstatSync(entriesDescriptor);
  let currentIdentity = `${current.dev}:${current.ino}`;
  const preparedPath = path.join(configuredStackRoot, record.preparedName);
  let prepared;
  try {
    prepared = fs.lstatSync(preparedPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    if (currentIdentity === record.oldIdentity) {
      removeStackControl(legacyCutoverName);
      return;
    }
    if (currentIdentity !== record.replacementIdentity) {
      throw new Error("legacy report cutover generation is missing and the active entries root is unowned");
    }
    removeStackControl(legacyCutoverName);
    return;
  }
  const preparedIdentity = `${prepared.dev}:${prepared.ino}`;
  if (!prepared.isDirectory() || prepared.isSymbolicLink()) throw new Error("legacy report cutover generation is not a real directory");
  if (currentIdentity === record.oldIdentity && preparedIdentity === record.replacementIdentity) {
    const replacement = pinnedDirectory(preparedPath, fs.realpathSync(configuredStackRoot), "legacy report cutover replacement");
    let copied = 0;
    let pending = false;
    let preparedStale = false;
    const cutoff = Date.now() - reportRetentionMs;
    const activeRoot = currentEntriesRoot();
    for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) {
        if (!entry.name.startsWith(".")) throw new Error(`invalid file in legacy report namespace: ${entry.name}`);
        continue;
      }
      const cohortDeadline = retentionCohortDeadline(entry.name);
      if (Number.isFinite(cohortDeadline)) {
        if (cohortDeadline <= Date.now()) {
          if (fs.existsSync(path.join(preparedPath, entry.name))) preparedStale = true;
          const observed = fs.statSync(entry.name, { bigint: true });
          moveEntryCohortToPrivate(entry.name, `${observed.dev}:${observed.ino}`);
          continue;
        }
        if (fs.existsSync(path.join(preparedPath, entry.name))) continue;
        if (copied >= reportRetentionBatch) { pending = true; continue; }
        runContainedHelper(["copy-directory-fd", entry.name, "-", entry.name], [entriesDescriptor, replacement.descriptor], 64 * 1024 * 1024);
        copied += 1;
        continue;
      }
      if (/^\.[a-zA-Z0-9][a-zA-Z0-9._-]*\.expired$/.test(entry.name)) continue;
      if (entry.name.startsWith(".") || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(entry.name)) {
        throw new Error(`invalid legacy report entry id at ${path.join(entriesDir, entry.name)}`);
      }
      const manifest = readEntryManifestAt(activeRoot, entry.name);
      if (!manifest || manifest.reportId !== entry.name) {
        throw new Error(`legacy report manifest identity mismatch at ${path.join(entriesDir, entry.name)}`);
      }
      const completedAt = Date.parse(manifest.completedAt);
      if (!Number.isFinite(completedAt)) throw new Error(`invalid legacy report completion time for ${entry.name}`);
      const cohortName = retentionCohortFor(manifest.completedAt);
      if (completedAt <= cutoff) {
        if (fs.existsSync(path.join(preparedPath, cohortName, entry.name))) preparedStale = true;
        const observed = fs.statSync(entry.name, { bigint: true });
        moveEntryCohortToPrivate(entry.name, `${observed.dev}:${observed.ino}`);
        continue;
      }
      if (fs.existsSync(path.join(preparedPath, cohortName, entry.name))) continue;
      if (copied >= reportRetentionBatch) { pending = true; continue; }
      runContainedHelper([
        "copy-directory-fd", entry.name, cohortName, entry.name,
      ], [entriesDescriptor, replacement.descriptor], 64 * 1024 * 1024);
      runContainedHelper(
        ["rebase-legacy-report-links-fd", cohortName, entry.name],
        [replacement.descriptor],
        1024 * 1024,
      );
      copied += 1;
    }
    if (preparedStale) {
      fs.closeSync(replacement.descriptor);
      moveStackDirectoryToPrivate(record.preparedName, record.replacementIdentity);
      removeStackControl(legacyCutoverName);
      throw new Error("legacy report migration staging expired; rerun retention");
    }
    if (pending) {
      if (process.env.FM_REPORT_LEGACY_CUTOVER_TEST_READY && process.env.FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED) {
        fs.writeFileSync(process.env.FM_REPORT_LEGACY_CUTOVER_TEST_READY, "ready\n", { flag: "wx" });
        while (!fs.existsSync(process.env.FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED)) {
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
        }
      }
      fs.closeSync(replacement.descriptor);
      return;
    }
    const oldDescriptor = entriesDescriptor;
    runContainedHelper(
      ["exchange-directories-fd", "entries", record.preparedName, record.oldIdentity, record.replacementIdentity],
      [stackRootDescriptor],
      1024 * 1024,
    );
    process.chdir(path.join(configuredStackRoot, "entries"));
    entriesDescriptor = replacement.descriptor;
    entriesDir = ".";
    fs.closeSync(oldDescriptor);
    current = fs.fstatSync(entriesDescriptor);
    currentIdentity = `${current.dev}:${current.ino}`;
    if (process.env.FM_REPORT_LEGACY_CUTOVER_TEST_READY && process.env.FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED) {
      fs.writeFileSync(process.env.FM_REPORT_LEGACY_CUTOVER_TEST_READY, "ready\n", { flag: "wx" });
      while (!fs.existsSync(process.env.FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED)) {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      }
    }
    prepared = fs.lstatSync(preparedPath);
  }
  if (currentIdentity !== record.replacementIdentity || `${prepared.dev}:${prepared.ino}` !== record.oldIdentity) {
    throw new Error("legacy report cutover generations no longer match their marker");
  }
  moveStackDirectoryToPrivate(record.preparedName, record.oldIdentity);
  removeStackControl(legacyCutoverName);
}

function cutoverLegacyEntries() {
  recoverLegacyCutover();
  if (readStackControl(legacyCutoverName) !== undefined) return;
  const entries = fs.readdirSync(entriesDir, { withFileTypes: true });
  const needsCutover = entries.some((entry) => (entry.isDirectory() && !entry.name.startsWith(".")
    && !Number.isFinite(retentionCohortDeadline(entry.name)))
    || (entry.isDirectory() && /^\.[a-zA-Z0-9][a-zA-Z0-9._-]*\.expired$/.test(entry.name)));
  if (!needsCutover) return;
  const preparedName = `.entries.cutover.${crypto.randomUUID()}`;
  const preparedPath = path.join(configuredStackRoot, preparedName);
  fs.mkdirSync(preparedPath, { mode: 0o700 });
  const prepared = pinnedDirectory(preparedPath, fs.realpathSync(configuredStackRoot), "legacy report cutover generation");
  const old = fs.fstatSync(entriesDescriptor);
  const oldIdentity = `${old.dev}:${old.ino}`;
  const replacementIdentity = `${prepared.dev}:${prepared.ino}`;
  publishStackControl(legacyCutoverName, {
    schemaVersion: 1,
    preparedName,
    oldIdentity,
    replacementIdentity,
  });
  fs.closeSync(prepared.descriptor);
  recoverLegacyCutover();
}

function readRetentionPolicy() {
  const framed = runContainedHelper(["read-fd", retentionPolicyName, "4096", "strict"], [stackRootDescriptor], 1024 * 1024);
  const item = framedItems(framed).get("source");
  if (!item || item.missing) return { schemaVersion: 1, generation: "", cutoffMs: Number.NEGATIVE_INFINITY };
  const source = item.content.toString("utf8").trim();
  const match = source.match(/^window\.firstmateRetentionPolicy=(\{.*\});$/);
  if (!match) throw new Error(`invalid report retention authority in ${retentionPolicyName}`);
  const policy = JSON.parse(match[1]);
  if (policy.schemaVersion !== 1 || typeof policy.generation !== "string" || !Number.isFinite(policy.cutoffMs)) {
    throw new Error(`invalid report retention authority in ${retentionPolicyName}`);
  }
  return policy;
}

function publishRetentionPolicy(policy) {
  const tempName = `.${retentionPolicyName}.${crypto.randomUUID()}.tmp`;
  const temp = path.join(entriesDir, tempName);
  const authority = JSON.stringify({ schemaVersion: 1, generation: policy.generation, cutoffMs: policy.cutoffMs });
  try {
    fs.writeFileSync(temp, `window.firstmateRetentionPolicy=${authority};\n`, { flag: "wx", mode: 0o600 });
    runContainedHelper(
      ["replace-file-fd", tempName, retentionPolicyName],
      [entriesDescriptor, stackRootDescriptor],
      1024 * 1024,
    );
  } finally {
    fs.rmSync(temp, { force: true });
  }
}

function reportTransactionPath(reportId) {
  return path.join(entriesDir, `.${reportId}.transaction`);
}

function writeReportTransaction(reportId, destinationCohort, previousCohort) {
  const transaction = reportTransactionPath(reportId);
  const temp = `${transaction}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temp, `${JSON.stringify({ schemaVersion: 2, reportId, destinationCohort, previousCohort })}\n`, { flag: "wx", mode: 0o600 });
    assertSafeFileDestination(transaction, "report transaction destination");
    fs.renameSync(temp, transaction);
  } finally {
    fs.rmSync(temp, { force: true });
  }
  return transaction;
}

function removeStagedReports(reportId) {
  const prefix = `.${reportId}.`;
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name.startsWith(prefix) && entry.name.endsWith(".tmp")) {
      fs.rmSync(path.join(entriesDir, entry.name), { recursive: true, force: true });
    }
  }
}

function removeAgedOrphanStaging(transactionIds) {
  const minimumAgeMs = 24 * 60 * 60 * 1000;
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.isDirectory() && entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.(?:[0-9]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.tmp$/i);
    if (!match || transactionIds.has(match[1])) continue;
    const staged = path.join(entriesDir, entry.name);
    if (Date.now() - fs.statSync(staged).mtimeMs < minimumAgeMs) continue;
    fs.rmSync(staged, { recursive: true, force: true });
  }
}

function entryRemainsIntact(cohortName, reportId) {
  if (!fs.existsSync(path.join(entriesDir, cohortName, reportId))) return false;
  let manifest;
  try {
    manifest = readEntryManifest(cohortName, reportId);
  } catch {
    return false;
  }
  return Boolean(manifest) && manifest.reportId === reportId;
}

function recoverPreviousEntries() {
  if (!fs.existsSync(entriesDir)) return;
  const transactions = [];
  const transactionIds = new Set();
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.transaction$/);
    if (!match) continue;
    if (!entry.isFile()) throw new Error(`invalid report transaction at ${path.join(entriesDir, entry.name)}`);
    const transaction = path.join(entriesDir, entry.name);
    const record = JSON.parse(readBoundedRegularFile(transaction, transactionLimit, "report transaction"));
    const reportId = match[1];
    if (record.schemaVersion !== 2 || record.reportId !== reportId
      || !Number.isFinite(retentionCohortDeadline(record.destinationCohort))
      || (record.previousCohort !== null && !Number.isFinite(retentionCohortDeadline(record.previousCohort)))) {
      throw new Error(`invalid report transaction at ${transaction}`);
    }
    const destination = path.join(entriesDir, record.destinationCohort, reportId);
    const previous = path.join(entriesDir, `.${reportId}.previous`);
    if (record.previousCohort !== null) {
      if (fs.existsSync(previous)) {
        fs.rmSync(destination, { recursive: true, force: true });
        const restoredCohort = path.join(entriesDir, record.previousCohort);
        try {
          fs.mkdirSync(restoredCohort, { mode: 0o700 });
        } catch (error) {
          if (error.code !== "EEXIST") throw error;
        }
        realDirectory(restoredCohort, fs.realpathSync(entriesDir), "restored report retention cohort");
        fs.renameSync(previous, path.join(restoredCohort, reportId));
      } else if (!fs.existsSync(destination) && !entryRemainsIntact(record.previousCohort, reportId)) {
        throw new Error(`report transaction lost both generations for ${reportId}`);
      }
    } else {
      if (fs.existsSync(previous)) throw new Error(`unexpected previous report generation for ${reportId}`);
      fs.rmSync(destination, { recursive: true, force: true });
    }
    transactions.push({ reportId, transaction });
    transactionIds.add(reportId);
  }

  const recoveredPrevious = [];
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.isDirectory() && entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.previous$/);
    if (!match) continue;
    if (transactionIds.has(match[1])) continue;
    const previous = path.join(entriesDir, entry.name);
    recoveredPrevious.push({ previous, discard: true });
  }

  if (transactions.length > 0 || recoveredPrevious.length > 0) renderIndex();
  for (const { reportId, transaction } of transactions) {
    removeStagedReports(reportId);
    fs.rmSync(transaction, { force: true });
  }
  for (const { previous, discard } of recoveredPrevious) {
    if (discard) fs.rmSync(previous, { recursive: true, force: true });
  }
  removeAgedOrphanStaging(transactionIds);
}

function nextRetentionPolicy() {
  if (!Number.isSafeInteger(reportRetentionBatch) || reportRetentionBatch <= 0) {
    throw new Error("FM_REPORT_RETENTION_BATCH must be a positive integer");
  }
  if (!Number.isSafeInteger(reportRetentionCohortMs) || reportRetentionCohortMs <= 0) {
    throw new Error("FM_REPORT_RETENTION_COHORT_MS must be a positive integer");
  }
  if (!Number.isSafeInteger(reportRetentionSweepSeconds) || reportRetentionSweepSeconds <= 0
    || !Number.isSafeInteger(reportRetentionSweepMs)) {
    throw new Error("FM_REPORT_RETENTION_INTERVAL must be a positive integer number of seconds");
  }
  if (reportRetentionCohortMs + reportRetentionSweepMs > reportRetentionDriftMs) {
    throw new Error("FM_REPORT_RETENTION_COHORT_MS plus FM_REPORT_RETENTION_INTERVAL must not exceed 15 days");
  }
  const previous = readRetentionPolicy();
  const policy = {
    schemaVersion: 1,
    generation: crypto.randomUUID(),
    cutoffMs: Math.max(previous.cutoffMs, Date.now() - reportRetentionMs),
  };
  return policy;
}

const retentionCutoverName = ".retention-cutover.json";

function recoverRetentionCutover() {
  const raw = readStackControl(retentionCutoverName);
  if (raw === undefined) return;
  const record = JSON.parse(raw);
  if (record.schemaVersion !== 1 || !/^\.entries\.retention\.[0-9a-f-]+$/.test(record.retiredName)
    || !/^tombstone-[0-9a-f-]+$/.test(record.tombstoneName)
    || !/^\d+:\d+$/.test(record.oldIdentity) || !/^\d+:\d+$/.test(record.replacementIdentity)
    || !Number.isFinite(record.dueBefore) || typeof record.policyGeneration !== "string"
    || !Number.isFinite(record.cutoffMs) || !Array.isArray(record.freshCohorts)
    || record.freshCohorts.some((item) => !item || !Number.isFinite(retentionCohortDeadline(item.name))
      || !/^\d+:\d+$/.test(item.identity))) {
    throw new Error(`invalid report retention cutover marker at ${retentionCutoverName}`);
  }
  const retiredPath = path.join(configuredStackRoot, record.retiredName);
  const tombstonePath = path.join(configuredStackRoot, ".retention-tombstones", record.tombstoneName);
  let current = fs.fstatSync(entriesDescriptor);
  let currentIdentity = `${current.dev}:${current.ino}`;
  let retiredStat;
  try {
    retiredStat = fs.lstatSync(retiredPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    const tombstone = fs.lstatSync(tombstonePath);
    if (!tombstone.isDirectory() || tombstone.isSymbolicLink()
      || `${tombstone.dev}:${tombstone.ino}` !== record.oldIdentity
      || currentIdentity !== record.replacementIdentity) {
      throw new Error("report retention cutover lost its retired namespace");
    }
    removeStackControl(retentionCutoverName);
    return;
  }
  const retiredIdentity = `${retiredStat.dev}:${retiredStat.ino}`;
  if (currentIdentity === record.oldIdentity && retiredIdentity === record.replacementIdentity) {
    const replacement = pinnedDirectory(retiredPath, fs.realpathSync(configuredStackRoot), "report retention replacement namespace");
    try {
      for (const item of record.freshCohorts) {
        const target = `../${record.retiredName}/${item.name}`;
        runContainedHelper(
          ["prepare-retention-link-fd", item.name, item.identity, target],
          [entriesDescriptor, replacement.descriptor],
          1024 * 1024,
        );
      }
      const oldDescriptor = entriesDescriptor;
      runContainedHelper(
        ["exchange-directories-fd", "entries", record.retiredName, record.oldIdentity, record.replacementIdentity],
        [stackRootDescriptor],
        1024 * 1024,
      );
      process.chdir(path.join(configuredStackRoot, "entries"));
      entriesDescriptor = replacement.descriptor;
      entriesDir = ".";
      fs.closeSync(oldDescriptor);
      current = fs.fstatSync(entriesDescriptor);
      currentIdentity = `${current.dev}:${current.ino}`;
      retiredStat = fs.lstatSync(retiredPath);
    } catch (error) {
      if (entriesDescriptor !== replacement.descriptor) fs.closeSync(replacement.descriptor);
      throw error;
    }
  }
  if (currentIdentity === record.replacementIdentity
    && `${retiredStat.dev}:${retiredStat.ino}` === record.oldIdentity) {
    const activePolicy = readRetentionPolicy();
    publishRetentionPolicy({
      schemaVersion: 1,
      generation: activePolicy.cutoffMs >= record.cutoffMs ? activePolicy.generation : record.policyGeneration,
      cutoffMs: Math.max(activePolicy.cutoffMs, record.cutoffMs),
    });
    if (process.env.FM_REPORT_RETENTION_POLICY_TEST_READY) {
      fs.writeFileSync(process.env.FM_REPORT_RETENTION_POLICY_TEST_READY, "ready\n", { flag: "wx" });
      if (process.env.FM_REPORT_RETENTION_POLICY_TEST_ABORT === "1") {
        throw new Error("report retention namespace test interruption");
      }
      if (process.env.FM_REPORT_RETENTION_POLICY_TEST_PROCEED) {
        while (!fs.existsSync(process.env.FM_REPORT_RETENTION_POLICY_TEST_PROCEED)) {
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
        }
      }
    }
    const retired = pinnedDirectory(retiredPath, fs.realpathSync(configuredStackRoot), "retired report namespace");
    try {
      for (const item of record.freshCohorts) {
        runContainedHelper(
          ["finalize-retention-link-fd", item.name, item.identity, `../${record.retiredName}/${item.name}`],
          [entriesDescriptor, retired.descriptor],
          1024 * 1024,
        );
      }
    } finally {
      fs.closeSync(retired.descriptor);
    }
    moveStackDirectoryToPrivate(record.retiredName, record.oldIdentity, record.tombstoneName);
    removeStackControl(retentionCutoverName);
    return;
  }
  throw new Error("report retention cutover generations no longer match their marker");
}

function expireDueCohorts(policy) {
  recoverRetentionCutover();
  if (readStackControl(legacyCutoverName) !== undefined) return;
  const dueBefore = Date.now();
  const entries = fs.readdirSync(entriesDir, { withFileTypes: true });
  const hasDue = entries.some((entry) => entry.isDirectory()
    && Number.isFinite(retentionCohortDeadline(entry.name))
    && retentionCohortDeadline(entry.name) <= dueBefore);
  if (!hasDue) {
    publishRetentionPolicy(policy);
    return;
  }
  const retiredName = `.entries.retention.${crypto.randomUUID()}`;
  const tombstoneName = `tombstone-${crypto.randomUUID()}`;
  const retiredPath = path.join(configuredStackRoot, retiredName);
  fs.mkdirSync(retiredPath, { mode: 0o700 });
  const replacement = pinnedDirectory(retiredPath, fs.realpathSync(configuredStackRoot), "report retention replacement namespace");
  const freshCohorts = [];
  for (const entry of entries) {
    const deadline = entry.isDirectory() ? retentionCohortDeadline(entry.name) : Number.NaN;
    if (Number.isFinite(deadline)) {
      if (deadline <= dueBefore) continue;
      const observed = fs.statSync(entry.name, { bigint: true });
      freshCohorts.push({ name: entry.name, identity: `${observed.dev}:${observed.ino}` });
      continue;
    }
    if (entry.name.startsWith(".")) continue;
    throw new Error(`invalid entry in report namespace during retention: ${entry.name}`);
  }
  const old = fs.fstatSync(entriesDescriptor);
  publishStackControl(retentionCutoverName, {
    schemaVersion: 1,
    retiredName,
    tombstoneName,
    oldIdentity: `${old.dev}:${old.ino}`,
    replacementIdentity: `${replacement.dev}:${replacement.ino}`,
    dueBefore,
    policyGeneration: policy.generation,
    cutoffMs: policy.cutoffMs,
    freshCohorts,
  });
  fs.closeSync(replacement.descriptor);
  recoverRetentionCutover();
}

function pruneExpiredEntries() {
  const raw = runContainedHelper(
    ["prune-tombstones-fd", String(reportRetentionBatch)],
    [retentionTombstoneDescriptor],
    1024 * 1024,
  ).toString("utf8");
  return JSON.parse(raw);
}

function renderIndex(policy = readRetentionPolicy()) {
  const tempName = `.index.html.${crypto.randomUUID()}.tmp`;
  const temp = path.join(entriesDir, tempName);
  try {
    fs.writeFileSync(temp, indexPage(readManifests(policy), policy), { flag: "wx", mode: 0o600 });
    runContainedHelper(
      ["replace-file-fd", tempName, "index.html"],
      [entriesDescriptor, stackRootDescriptor],
      1024 * 1024,
    );
  } finally {
    fs.rmSync(temp, { force: true });
  }
}

function publish(taskId, legacy) {
  if (!taskId || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(taskId)) throw new Error("publish requires a safe task id");
  const dataRoot = pinnedDirectory(dataDir, undefined, "configured data root");
  const stateRoot = pinnedDirectory(stateDir, undefined, "configured state root");
  try {
    const metaFile = path.join(stateDir, `${taskId}.meta`);
    const metaSource = readArtifact(metaFile, stateRoot, "task metadata", { maxBytes: metadataLimit });
    if (metaSource === undefined) throw new Error(`no task metadata at ${metaFile}`);
    const meta = parseMeta(metaSource);
    if (meta.kind === "secondmate") throw new Error("persistent secondmate retirement is not a completion report");
    const taskData = path.join(dataDir, taskId);
    const sourceName = meta.kind === "scout" ? "report.md" : "completion.md";
    const sourceFile = path.join(taskData, sourceName);
    const statusFile = path.join(stateDir, `${taskId}.status`);
    const id = stableReportId(taskId);
    const previous = path.join(entriesDir, `.${id}.previous`);
    const existing = findReportEntry(id);
    let previousManifest;
    if (existing) {
      realDirectory(existing.path, fs.realpathSync(path.dirname(existing.path)), "existing report entry");
      previousManifest = readEntryManifest(existing.cohort, id, "existing report manifest");
      if (!previousManifest) throw new Error(`existing report entry is incomplete at ${existing.path}`);
    }
    const staged = path.join(entriesDir, `.${id}.${crypto.randomUUID()}.tmp`);
    let stagedIdentity;
    let transaction;
    let publicationInstalled = false;
    fs.mkdirSync(staged, { mode: 0o700 });
    const stagedStat = fs.lstatSync(staged);
    stagedIdentity = `${stagedStat.dev}:${stagedStat.ino}`;
    try {
      const statusArtifact = snapshotStateArtifact(
        stateRoot,
        statusFile,
        staged,
        "status.log",
        informationalTrailLimit,
        "tail",
        "status trail",
      );
      const status = statusArtifact.view;
      const taskArtifacts = snapshotTaskArtifacts(dataRoot, taskId, sourceName, staged, sourceFile);
      const brief = taskArtifacts.brief;
      const source = taskArtifacts.source;
      const visuals = taskArtifacts.visuals;
      let markdown;
      if (source !== undefined) {
        if (meta.report_required === "1") requireCompletionSections(source, sourceFile, taskId);
        markdown = source;
      } else if (legacy && meta.report_required !== "1") markdown = `# ${titleFromBrief(taskId, brief)}\n\n## Summary\n\n${lastStatus(status)}\n\n## Preserved trail\n\nThis compatibility report was synthesized for a task created before completion reports were required.\nSee the attached task brief and status trail for details.\n`;
      else throw new Error(`required completion report is missing at ${sourceFile}`);
      if (!markdown.trim()) throw new Error(`completion report is empty at ${sourceFile}`);

      const worktreeHead = gitValue(meta.worktree, ["rev-parse", "--short=12", "HEAD"]);
      const prHead = displaySha(meta.pr_head);
      const generationId = meta.generation_id || "";
      const previousWorktreeHead = previousManifest?.worktreeHead || previousManifest?.commit || "";
      const sameGeneration = previousManifest && (generationId || previousManifest.generationId)
        ? Boolean(generationId && previousManifest.generationId && generationId === previousManifest.generationId)
        : previousManifest
          && (!worktreeHead || previousWorktreeHead === worktreeHead)
          && previousManifest.harness === (meta.harness || "unknown")
          && (previousManifest.accountProfile || "") === (meta.account_profile || "");
      const branch = gitValue(meta.worktree, ["branch", "--show-current"]);
      const publishedWorktreeHead = worktreeHead || (sameGeneration ? previousWorktreeHead : "");
      const publishedCommit = worktreeHead || (sameGeneration ? previousManifest?.commit || previousWorktreeHead : "");
      const publishedBranch = branch || (sameGeneration ? previousManifest?.branch || "" : "");
      const manifest = {
        schemaVersion: 1,
        reportId: id,
        taskId,
        title: titleFromBrief(taskId, brief),
        summary: firstSummary(markdown, lastStatus(status)),
        completedAt: sameGeneration ? previousManifest.completedAt : new Date().toISOString(),
        kind: meta.kind || "ship",
        mode: meta.mode || "no-mistakes",
        project: meta.project ? path.basename(meta.project) : "unknown",
        harness: meta.harness || "unknown",
        accountProfile: meta.account_profile || "",
        ...(generationId ? { generationId } : {}),
        prUrl: safeHttpUrl(meta.pr),
        commit: publishedCommit,
        worktreeHead: publishedWorktreeHead,
        ...(prHead ? { prHead } : {}),
        branch: publishedBranch,
        visuals,
      };
      manifest.retentionCohort = retentionCohortFor(manifest.completedAt);
      fs.writeFileSync(path.join(staged, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
      if (!taskArtifacts.sourcePresent) fs.writeFileSync(path.join(staged, "report.md"), markdown, { mode: 0o600 });
      if (!taskArtifacts.briefPresent) fs.writeFileSync(path.join(staged, "brief.md"), "Task brief unavailable.\n", { mode: 0o600 });
      if (!statusArtifact.present) fs.writeFileSync(path.join(staged, "status.log"), "Status trail unavailable.\n", { mode: 0o600 });
      fs.writeFileSync(path.join(staged, "report.html"), reportPage(manifest, markdown, visuals), { mode: 0o600 });

      const hadPrevious = Boolean(existing);
      const previousStat = existing ? fs.lstatSync(existing.path) : undefined;
      const previousIdentity = previousStat ? `${previousStat.dev}:${previousStat.ino}` : "-";
      transaction = writeReportTransaction(id, manifest.retentionCohort, existing?.cohort || null);
      runContainedHelper(
        ["publish-report-fd", path.basename(staged), manifest.retentionCohort, id, stagedIdentity,
          existing?.cohort || "-", previousIdentity],
        [entriesDescriptor],
        1024 * 1024,
      );
      publicationInstalled = true;
      try {
        renderIndex();
      } catch (error) {
        runContainedHelper(
          ["rollback-report-fd", manifest.retentionCohort, id, stagedIdentity,
            existing?.cohort || "-", previousIdentity, `.${id}.failed.${crypto.randomUUID()}`],
          [entriesDescriptor],
          1024 * 1024,
        );
        fs.rmSync(transaction, { force: true });
        transaction = undefined;
        publicationInstalled = false;
        throw error;
      }
      fs.rmSync(transaction, { force: true });
      transaction = undefined;
      if (hadPrevious) {
        runContainedHelper(
          ["remove-owned-tree-fd", path.basename(previous), previousIdentity],
          [entriesDescriptor, retentionTombstoneDescriptor],
          1024 * 1024,
        );
      }
      console.log(`published ${taskId} ${path.join(configuredStackRoot, "entries", manifest.retentionCohort, id, "report.html")}`);
    } catch (error) {
      if (transaction && fs.existsSync(transaction)) {
        if (!publicationInstalled) {
          fs.rmSync(transaction, { force: true });
          transaction = undefined;
        } else {
          try {
            recoverPreviousEntries();
          } catch (recoveryError) {
            error.message = `${error.message}; report transaction recovery remains pending: ${recoveryError.message}`;
          }
        }
      }
      throw error;
    } finally {
      if (stagedIdentity && fs.existsSync(staged)) {
        try {
          runContainedHelper(
            ["remove-owned-tree-fd", path.basename(staged), stagedIdentity],
            [entriesDescriptor, retentionTombstoneDescriptor],
            1024 * 1024,
          );
        } catch {}
      }
    }
  } finally {
    fs.closeSync(stateRoot.descriptor);
    fs.closeSync(dataRoot.descriptor);
  }
}

function resolveReportPath(taskId) {
  if (!taskId) return path.join(configuredStackRoot, "index.html");
  const rows = readManifests();
  const exact = rows.find((row) => row.reportId === taskId);
  if (exact) return path.join(configuredStackRoot, "entries", exact.retentionCohort, exact.reportId, "report.html");
  const matches = rows.filter((row) => row.taskId === taskId);
  if (matches.length === 0) throw new Error(`no report found for ${taskId}`);
  if (matches.length > 1) {
    throw new Error(`task id ${taskId} is ambiguous; use one of these report ids: ${matches.map((row) => row.reportId).join(", ")}`);
  }
  return path.join(configuredStackRoot, "entries", matches[0].retentionCohort, matches[0].reportId, "report.html");
}

refuseIfGateAgent();

try {
  if (command === "publish") {
    withLock(() => publish(args.find((arg) => !arg.startsWith("--")), args.includes("--legacy")));
  } else if (command === "render") {
    withLock(renderIndex);
    console.log(path.join(configuredStackRoot, "index.html"));
  } else if (command === "list") {
    const rows = withLock(readManifests);
    if (args.includes("--json")) console.log(JSON.stringify(rows, null, 2));
    else for (const row of rows) console.log(`${row.completedAt}\t${row.taskId}\t${row.kind}\t${row.title}`);
  } else if (command === "path") {
    console.log(withLock(() => resolveReportPath(args[0])));
  } else if (command === "open") {
    const target = withLock(() => {
      renderIndex();
      return resolveReportPath(args[0]);
    });
    execFileSync(process.platform === "darwin" ? "open" : "xdg-open", [target], { stdio: "ignore" });
    console.log(target);
  } else if (command === "prune") {
    withLock(() => {});
    if (args.includes("--status")) console.log(JSON.stringify(lastPruneStatus));
  } else {
    fail(`unknown command: ${command}`);
  }
} catch (error) {
  fail(error.message);
}
