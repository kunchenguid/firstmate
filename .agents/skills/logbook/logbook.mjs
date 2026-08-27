#!/usr/bin/env node
/**
 * Firstmate Logbook v1 deterministic state helper.
 *
 * The user-facing data schema and transition contract live only in SKILL.md.
 * This executable enforces that contract and owns the exact command interface.
 *
 * Usage:
 *   logbook.mjs start --mission <text> [--input <json-file|->]
 *   logbook.mjs update --mission <text> --input <json-file|->
 *   logbook.mjs close --mission <text> --input <json-file|->
 *   logbook.mjs active
 *   logbook.mjs path --mission <text>
 *
 * start   Create a self-contained mission page and active registration, or
 *         resume the same active mission without rewriting the page.
 * update  Validate one meaningful update, apply legal gate/resource/blocker
 *         transitions, prepend its milestone, and atomically replace only the
 *         page's uniquely delimited embedded payload block.
 * close   Validate and append the final outcome, atomically publish the closed
 *         page, and remove the active registration.
 * active  Print the validated active mission and artifact paths, or "inactive".
 * path    Print the confined page path for a mission without creating it.
 *
 * FM_HOME selects the private Firstmate home.
 * FM_LOGBOOK_TEMPLATE overrides the shipped shell path for tests only.
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PAYLOAD_SCHEMA = "firstmate-logbook.v1";
const REGISTRATION_SCHEMA = "firstmate-logbook-active.v1";
const PAYLOAD_BEGIN = "<!-- FIRSTMATE_LOGBOOK_PAYLOAD_BEGIN -->";
const PAYLOAD_END = "<!-- FIRSTMATE_LOGBOOK_PAYLOAD_END -->";
const PAYLOAD_PLACEHOLDER = "__FIRSTMATE_LOGBOOK_PAYLOAD__";
const UPDATE_KINDS = new Set([
  "start",
  "stage-change",
  "verification",
  "diagnosed-failure",
  "resource-change",
  "blocker",
  "stage-completion",
  "checkpoint",
  "close",
]);
const GATE_STATES = new Set(["queued", "active", "passed", "blocked"]);
const RESOURCE_STATES = new Set(["within-boundary", "near-boundary", "boundary-reached", "changed"]);
const BLOCKER_STATES = new Set(["open", "resolved"]);
const OUTCOMES = new Set(["completed", "stopped", "failed"]);
const CHECKPOINT_INTERVAL_MS = 6 * 60 * 60 * 1000;
const MAX_MISSION = 120;
const MAX_TITLE = 120;
const MAX_SUMMARY = 600;
const MAX_SNAPSHOT = 240;
const MAX_DETAIL = 1200;
const MAX_ITEMS = 64;
const MAX_GATES = 24;
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,79}$/;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const HTTPS_RE = /^https:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^\s]*)?$/;
const INTERNAL_RE = /\b(?:crewmate|worktree|checkout|teardown|wake(?:s| queue)?|watcher|heartbeat|harness|runtime backend|task id|status file|metadata file|delivery mode|yolo)\b/i;
const RAW_EVENT_RE = /^(?:working|done|blocked|paused|failed|needs-decision|resolved):/i;
const UNSUPPORTED_PROGRESS_RE = /%|\bpercent\b|\bhalfway\b|\b(?:almost|nearly)\s+(?:done|complete)\b/i;
const SECRET_PATTERNS = [
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
  /\b(?:ghp|github_pat|xox[baprs]|sk)_[A-Za-z0-9_-]{12,}\b/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}\b/i,
  /\b(?:password|passwd|secret|token|api[_ -]?key|private[_ -]?key)\s*[:=]\s*\S+/i,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
];

function usage(message) {
  if (message) process.stderr.write(`logbook: ${message}\n`);
  const source = fs.readFileSync(fileURLToPath(import.meta.url), "utf8");
  const block = source.match(/\/\*\*\n([\s\S]*?)\n \*\//)?.[1] ?? "";
  process.stderr.write(block.split("\n").map((line) => line.replace(/^ \* ?/, "")).join("\n") + "\n");
  process.exit(message ? 2 : 0);
}

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const command = argv.shift();
  if (!command || ["-h", "--help", "help"].includes(command)) usage();
  const opts = {};
  while (argv.length) {
    const key = argv.shift();
    if (key === "--mission" || key === "--input") {
      if (!argv.length) usage(`${key} needs a value`);
      opts[key.slice(2)] = argv.shift();
    } else {
      usage(`unknown argument: ${key}`);
    }
  }
  return { command, opts };
}

function realHome() {
  const requested = process.env.FM_HOME || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
  if (!fs.existsSync(requested)) fail(`FM_HOME does not exist: ${requested}`);
  const home = fs.realpathSync(requested);
  if (!fs.statSync(home).isDirectory()) fail(`FM_HOME is not a directory: ${requested}`);
  return home;
}

function assertInside(root, candidate) {
  const relative = path.relative(root, candidate);
  if (relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative))) return;
  fail(`path escapes the logbook root: ${candidate}`);
}

function ensureDirectory(candidate, parentRoot, mode = 0o700) {
  assertInside(parentRoot, candidate);
  if (mode !== 0o700) fail("unsupported confined directory mode");
  confinedFile("mkdir", parentRoot, candidate);
}

function assertDirectoryChain(candidate, root) {
  assertInside(root, candidate);
  const relative = path.relative(root, candidate);
  let current = root;
  const rootStat = fs.lstatSync(current);
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) fail(`unsafe directory component: ${current}`);
  if (!relative) return;
  for (const part of relative.split(path.sep)) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`unsafe directory component: ${current}`);
  }
}

function assertRegularOrAbsent(candidate, root) {
  assertInside(root, candidate);
  assertDirectoryChain(path.dirname(candidate), root);
  if (!fs.existsSync(candidate)) return;
  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`unsafe logbook file: ${candidate}`);
}

function layout(home, mission) {
  validateText(mission, "mission", MAX_MISSION, { scanInternal: true });
  const normalized = mission.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
  let stem = normalized.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 56);
  if (!stem) stem = "mission";
  const digest = crypto.createHash("sha256").update(mission, "utf8").digest("hex").slice(0, 10);
  const missionId = `${stem}-${digest}`;
  if (!SLUG_RE.test(missionId)) fail("could not derive a safe mission id");
  const data = path.join(home, "data");
  const root = path.join(data, "logbook");
  const missions = path.join(root, "missions");
  const dir = path.join(missions, missionId);
  const page = path.join(dir, "index.html");
  const registration = path.join(root, "active.json");
  const lock = path.join(root, ".writer.lock");
  [data, root, missions, dir, page, registration, lock].forEach((p) => assertInside(home, p));
  return { home, data, root, missions, dir, page, registration, lock, missionId };
}

function validateText(value, label, max, options = {}) {
  const { allowEmpty = false, scanInternal = true } = options;
  if (typeof value !== "string") fail(`${label} must be text`);
  if ((!allowEmpty && value.trim().length === 0) || value.length > max) fail(`${label} has an invalid length`);
  if (/[\u0000-\u001f\u007f]/.test(value)) fail(`${label} contains control characters or multiple lines`);
  if (RAW_EVENT_RE.test(value.trim())) fail(`${label} looks like raw worker output`);
  if (scanInternal && INTERNAL_RE.test(value)) fail(`${label} contains private supervision vocabulary`);
  if (UNSUPPORTED_PROGRESS_RE.test(value)) fail(`${label} contains an unsupported progress claim`);
  for (const pattern of SECRET_PATTERNS) {
    if (pattern.test(value)) fail(`${label} appears to contain a secret or credential value`);
  }
  return value;
}

function assertKeys(object, allowed, label) {
  if (!object || typeof object !== "object" || Array.isArray(object)) fail(`${label} must be an object`);
  for (const key of Object.keys(object)) {
    if (!allowed.includes(key)) fail(`${label} contains unknown field: ${key}`);
  }
}

function validateEvidence(items, label, { requireOne = false } = {}) {
  if (!Array.isArray(items) || items.length > MAX_ITEMS || (requireOne && items.length === 0)) {
    fail(`${label} must be ${requireOne ? "a non-empty" : "an"} evidence array`);
  }
  return items.map((item, index) => {
    const here = `${label}[${index}]`;
    assertKeys(item, ["label", "value", "href"], here);
    validateText(item.label, `${here}.label`, 80);
    validateText(item.value, `${here}.value`, MAX_DETAIL);
    if (item.href !== undefined && (typeof item.href !== "string" || !HTTPS_RE.test(item.href))) {
      fail(`${here}.href must be an HTTPS URL`);
    }
    return { label: item.label, value: item.value, ...(item.href ? { href: item.href } : {}) };
  });
}

function validateSnapshot(snapshot, label = "snapshot") {
  assertKeys(snapshot, ["done", "now", "next", "eli5", "orientation"], label);
  const eli5 = snapshot.eli5 === true;
  if (snapshot.eli5 !== undefined && typeof snapshot.eli5 !== "boolean") fail(`${label}.eli5 must be true or false`);
  const result = {
    done: validateText(snapshot.done, `${label}.done`, MAX_SNAPSHOT),
    now: validateText(snapshot.now, `${label}.now`, MAX_SNAPSHOT),
    next: validateText(snapshot.next, `${label}.next`, MAX_SNAPSHOT),
    eli5,
  };
  if (eli5) {
    result.orientation = validateText(snapshot.orientation, `${label}.orientation`, MAX_SNAPSHOT);
    for (const key of ["done", "now", "next"]) {
      if (result[key].trim().split(/\s+/).length > 18) fail(`${label}.${key} exceeds the ELI5 visible-word limit`);
    }
  } else if (snapshot.orientation !== undefined) {
    result.orientation = validateText(snapshot.orientation, `${label}.orientation`, MAX_SNAPSHOT);
  }
  return result;
}

function validateGates(items, label = "gates", { requireOne = false } = {}) {
  if (!Array.isArray(items) || items.length > MAX_GATES || (requireOne && items.length === 0)) fail(`${label} must be a finite gate array`);
  const ids = new Set();
  return items.map((item, index) => {
    const here = `${label}[${index}]`;
    assertKeys(item, ["id", "label", "state", "evidence"], here);
    if (typeof item.id !== "string" || !ID_RE.test(item.id)) fail(`${here}.id must be a safe identifier`);
    if (ids.has(item.id)) fail(`${label} repeats gate id: ${item.id}`);
    ids.add(item.id);
    validateText(item.label, `${here}.label`, MAX_TITLE);
    if (!GATE_STATES.has(item.state)) fail(`${here}.state is not supported`);
    return { id: item.id, label: item.label, state: item.state, evidence: validateEvidence(item.evidence || [], `${here}.evidence`) };
  });
}

function validateBlockers(items, label = "blockers") {
  if (!Array.isArray(items) || items.length > MAX_ITEMS) fail(`${label} must be an array`);
  const ids = new Set();
  return items.map((item, index) => {
    const here = `${label}[${index}]`;
    assertKeys(item, ["id", "summary", "state", "evidence"], here);
    if (typeof item.id !== "string" || !ID_RE.test(item.id) || ids.has(item.id)) fail(`${here}.id must be unique and safe`);
    ids.add(item.id);
    validateText(item.summary, `${here}.summary`, MAX_SUMMARY);
    if (!BLOCKER_STATES.has(item.state)) fail(`${here}.state is not supported`);
    return { id: item.id, summary: item.summary, state: item.state, evidence: validateEvidence(item.evidence || [], `${here}.evidence`, { requireOne: true }) };
  });
}

function validateResources(items, label = "resources") {
  if (!Array.isArray(items) || items.length > MAX_ITEMS) fail(`${label} must be an array`);
  const ids = new Set();
  return items.map((item, index) => {
    const here = `${label}[${index}]`;
    assertKeys(item, ["id", "label", "boundary", "state", "evidence"], here);
    if (typeof item.id !== "string" || !ID_RE.test(item.id) || ids.has(item.id)) fail(`${here}.id must be unique and safe`);
    ids.add(item.id);
    validateText(item.label, `${here}.label`, MAX_TITLE);
    validateText(item.boundary, `${here}.boundary`, MAX_SUMMARY);
    if (!RESOURCE_STATES.has(item.state)) fail(`${here}.state is not supported`);
    return { id: item.id, label: item.label, boundary: item.boundary, state: item.state, evidence: validateEvidence(item.evidence || [], `${here}.evidence`, { requireOne: true }) };
  });
}

function validateUpdate(input, command) {
  assertKeys(input, ["kind", "title", "summary", "snapshot", "gates", "blockers", "resources", "evidence", "outcome", "final_outcome"], "update");
  if (!UPDATE_KINDS.has(input.kind)) fail("update.kind is not a meaningful logbook event");
  if (command === "start" && input.kind !== "start") fail("start input must use kind=start");
  if (command === "update" && ["start", "close"].includes(input.kind)) fail("update cannot use start or close kind");
  if (command === "close" && input.kind !== "close") fail("close input must use kind=close");
  validateText(input.title, "update.title", MAX_TITLE);
  validateText(input.summary, "update.summary", MAX_SUMMARY);
  const update = {
    kind: input.kind,
    title: input.title,
    summary: input.summary,
    snapshot: validateSnapshot(input.snapshot),
    evidence: validateEvidence(input.evidence, "update.evidence", { requireOne: true }),
  };
  if (input.gates !== undefined) update.gates = validateGates(input.gates, "update.gates", { requireOne: command === "start" });
  if (input.blockers !== undefined) update.blockers = validateBlockers(input.blockers, "update.blockers");
  if (input.resources !== undefined) update.resources = validateResources(input.resources, "update.resources");
  if (command === "close") {
    if (!OUTCOMES.has(input.outcome)) fail("close outcome must be completed, stopped, or failed");
    update.outcome = input.outcome;
    update.final_outcome = validateText(input.final_outcome, "update.final_outcome", MAX_SUMMARY);
  } else if (input.outcome !== undefined || input.final_outcome !== undefined) {
    fail("only close may set a final outcome");
  }
  return update;
}

function defaultStart(mission) {
  return validateUpdate({
    kind: "start",
    title: "Mission started",
    summary: `${mission} now has a durable progress page.`,
    snapshot: {
      done: "The mission and its reporting page are established.",
      now: "The mission is under way.",
      next: "Record the next meaningful stage change.",
    },
    gates: [
      { id: "mission-start", label: "Mission started", state: "passed", evidence: [{ label: "Mission", value: mission }] },
      { id: "mission-outcome", label: "Mission outcome achieved", state: "active", evidence: [] },
      { id: "verification", label: "Outcome verified", state: "queued", evidence: [] },
    ],
    blockers: [],
    resources: [],
    evidence: [{ label: "Mission", value: mission }],
  }, "start");
}

function readInput(source, required) {
  if (!source) {
    if (required) usage("--input is required");
    return undefined;
  }
  let bytes;
  try {
    bytes = source === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(source, "utf8");
  } catch (error) {
    fail(`cannot read update JSON: ${error.message}`);
  }
  try {
    return JSON.parse(bytes);
  } catch {
    fail("update input is not valid JSON");
  }
}

function atomicHelper() {
  const helper = path.join(path.dirname(fileURLToPath(import.meta.url)), "logbook-atomic.py");
  if (!fs.existsSync(helper) || fs.lstatSync(helper).isSymbolicLink() || !fs.statSync(helper).isFile()) {
    fail("confined file helper is missing");
  }
  return helper;
}

function relativePath(home, file) {
  assertInside(home, file);
  const relative = path.relative(home, file).split(path.sep).join("/");
  if (!relative || relative.split("/").some((part) => !part || part === "." || part === "..")) fail("unsafe confined file path");
  return relative;
}

function confinedResult(command, home, file, content) {
  return spawnSync(process.env.FM_LOGBOOK_PYTHON || "python3", [atomicHelper(), command, home, relativePath(home, file)], {
    input: content,
    encoding: "buffer",
    maxBuffer: Infinity,
  });
}

function confinedFile(command, home, file, content) {
  const result = confinedResult(command, home, file, content);
  if (result.error || result.status !== 0) fail("confined file operation failed");
  return result.stdout;
}

function claimConfinedDirectory(home, directory) {
  const result = confinedResult("claim", home, directory);
  if (result.status === 17) {
    const error = new Error("writer lock already exists");
    error.code = "EEXIST";
    throw error;
  }
  if (result.error || result.status !== 0) fail("confined writer lock operation failed");
}

function readJson(file, label, home, root) {
  assertRegularOrAbsent(file, root);
  let value;
  try {
    value = JSON.parse(confinedFile("read", home, file).toString("utf8"));
  } catch {
    fail(`${label} is not valid JSON: ${file}`);
  }
  return value;
}

function writeAtomicContent(file, content, home, root) {
  assertRegularOrAbsent(file, root);
  confinedFile("publish", home, file, Buffer.from(content, "utf8"));
}

function writeAtomicJson(file, value, home, root) {
  writeAtomicContent(file, `${JSON.stringify(value, null, 2)}\n`, home, root);
}

function removeConfinedFile(file, home, root) {
  assertRegularOrAbsent(file, root);
  confinedFile("remove", home, file);
}

function countOccurrences(content, needle) {
  return content.split(needle).length - 1;
}

function payloadBlock(payload) {
  const json = JSON.stringify(payload, null, 2).replaceAll("<", "\\u003c");
  return `${PAYLOAD_BEGIN}\n<script id="firstmate-logbook-data" type="application/json">\n${json}\n</script>\n${PAYLOAD_END}`;
}

function replacePayloadBlock(content, replacement) {
  if (countOccurrences(content, PAYLOAD_BEGIN) !== 1 || countOccurrences(content, PAYLOAD_END) !== 1) {
    fail("page must contain exactly one delimited payload block");
  }
  const begin = content.indexOf(PAYLOAD_BEGIN);
  const end = content.indexOf(PAYLOAD_END, begin) + PAYLOAD_END.length;
  if (end <= begin) fail("page payload delimiters are out of order");
  return `${content.slice(0, begin)}${replacement}${content.slice(end)}`;
}

function buildPage(template, payload) {
  const source = fs.readFileSync(template, "utf8");
  if (countOccurrences(source, PAYLOAD_PLACEHOLDER) !== 1) fail("logbook shell must contain exactly one payload placeholder");
  const expected = `${PAYLOAD_BEGIN}\n${PAYLOAD_PLACEHOLDER}\n${PAYLOAD_END}`;
  if (!source.includes(expected)) fail("logbook shell payload placeholder is not uniquely delimited");
  return source.replace(expected, payloadBlock(payload));
}

function readEmbeddedPayload(file, home, root) {
  assertRegularOrAbsent(file, root);
  const content = confinedFile("read", home, file).toString("utf8");
  if (countOccurrences(content, PAYLOAD_BEGIN) !== 1 || countOccurrences(content, PAYLOAD_END) !== 1) {
    fail(`page does not contain exactly one delimited payload: ${file}`);
  }
  const begin = content.indexOf(PAYLOAD_BEGIN);
  const end = content.indexOf(PAYLOAD_END, begin);
  if (end <= begin) fail(`page payload delimiters are out of order: ${file}`);
  const block = content.slice(begin + PAYLOAD_BEGIN.length, end).trim();
  const match = block.match(/^<script id="firstmate-logbook-data" type="application\/json">\n([\s\S]*)\n<\/script>$/);
  if (!match) fail(`page payload block has an invalid shape: ${file}`);
  try {
    return { content, payload: JSON.parse(match[1]) };
  } catch {
    fail(`embedded payload is not valid JSON: ${file}`);
  }
}

function writePagePayload(file, payload, home, root) {
  assertRegularOrAbsent(file, root);
  const { content } = readEmbeddedPayload(file, home, root);
  writeAtomicContent(file, replacePayloadBlock(content, payloadBlock(payload)), home, root);
}

function readWriterOwner(file, home, root) {
  try {
    const value = readJson(file, "writer owner record", home, root);
    if (!value || typeof value !== "object" || Array.isArray(value)
      || !/^[a-f0-9]{32}$/.test(value.token)
      || !Number.isInteger(value.pid) || value.pid <= 0
      || !Number.isFinite(Date.parse(value.claimed_at))) {
      throw new Error("invalid writer owner record");
    }
    return value;
  } catch {
    return undefined;
  }
}

function writerLockVanished(lock) {
  try {
    fs.lstatSync(lock);
    return false;
  } catch (error) {
    if (error.code === "ENOENT") return true;
    throw error;
  }
}

function acquireWriter(layout) {
  ensureDirectory(layout.data, layout.home);
  ensureDirectory(layout.root, layout.home);
  const owner = path.join(layout.lock, "owner.json");
  const token = crypto.randomBytes(16).toString("hex");
  const claim = () => {
    claimConfinedDirectory(layout.home, layout.lock);
    writeAtomicContent(owner, `${JSON.stringify({ token, pid: process.pid, claimed_at: new Date().toISOString() })}\n`, layout.home, layout.root);
  };
  while (true) {
    try {
      claim();
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      assertDirectoryChain(layout.root, layout.home);
      let stat;
      try {
        stat = fs.lstatSync(layout.lock);
      } catch (inspectError) {
        if (inspectError.code === "ENOENT") continue;
        throw inspectError;
      }
      if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`unsafe writer lock: ${layout.lock}`);
      if (!fs.existsSync(owner)) {
        if (writerLockVanished(layout.lock)) continue;
        fail("writer lock ownership is indeterminate");
      } else {
        const ownerValue = readWriterOwner(owner, layout.home, layout.root);
        if (!ownerValue) {
          if (writerLockVanished(layout.lock)) continue;
          fail("writer lock ownership is indeterminate");
        }
        const { pid } = ownerValue;
        let live = false;
        try { process.kill(pid, 0); live = true; } catch (probe) { if (probe.code === "EPERM") live = true; }
        if (live) fail(`another logbook writer is active (pid ${pid})`);
      }
      const stale = `${layout.lock}.stale.${process.pid}.${crypto.randomBytes(4).toString("hex")}`;
      try {
        fs.renameSync(layout.lock, stale);
      } catch (renameError) {
        if (renameError.code === "ENOENT") continue;
        throw renameError;
      }
      try { fs.rmSync(stale, { recursive: true, force: true }); } catch {}
    }
  }
  let released = false;
  return () => {
    if (released) return;
    released = true;
    try {
      assertDirectoryChain(layout.root, layout.home);
      const value = readJson(owner, "writer owner record", layout.home, layout.root);
      if (value?.token === token) fs.rmSync(layout.lock, { recursive: true, force: true });
    } catch {}
  };
}

function validateRegistration(value, root) {
  assertKeys(value, ["schema", "mission_id", "mission", "page", "started_at"], "active registration");
  if (value.schema !== REGISTRATION_SCHEMA) fail("active registration has the wrong schema");
  if (typeof value.mission_id !== "string" || !SLUG_RE.test(value.mission_id)) fail("active registration has an unsafe mission id");
  validateText(value.mission, "active registration mission", MAX_MISSION, { scanInternal: true });
  if (typeof value.page !== "string" || path.isAbsolute(value.page)) fail("active registration page must be a relative path");
  assertInside(root, path.resolve(root, value.page));
  if (!Number.isFinite(Date.parse(value.started_at))) fail("active registration has an invalid start time");
  return value;
}

function validateMilestone(value, label) {
  assertKeys(value, ["id", "at", "kind", "title", "summary", "evidence", "fingerprint"], label);
  if (typeof value.id !== "string" || !ID_RE.test(value.id)) fail(`${label}.id is unsafe`);
  if (!Number.isFinite(Date.parse(value.at))) fail(`${label}.at is invalid`);
  if (!UPDATE_KINDS.has(value.kind)) fail(`${label}.kind is invalid`);
  validateText(value.title, `${label}.title`, MAX_TITLE);
  validateText(value.summary, `${label}.summary`, MAX_SUMMARY);
  validateEvidence(value.evidence, `${label}.evidence`, { requireOne: true });
  if (typeof value.fingerprint !== "string" || !/^[a-f0-9]{64}$/.test(value.fingerprint)) fail(`${label}.fingerprint is invalid`);
  return value;
}

function milestonePrefix(at) {
  return at.replace(/[-:]/g, "").replace(".000", "");
}

function validateMilestoneHistory(items) {
  let previousAt = Infinity;
  const fingerprints = new Set();
  items.forEach((item, index) => {
    const label = `payload.milestones[${index}]`;
    validateMilestone(item, label);
    const timestamp = Date.parse(item.at);
    if (new Date(timestamp).toISOString() !== item.at) fail(`${label}.at is not canonical`);
    if (timestamp > previousAt) fail("payload milestones are not newest first");
    previousAt = timestamp;
    const prefix = milestonePrefix(item.at);
    if (item.id !== prefix && !new RegExp(`^${prefix}-[0-9]{2,}$`).test(item.id)) fail(`${label}.id is not timestamp-derived`);
    if (fingerprints.has(item.fingerprint)) fail(`payload repeats milestone fingerprint: ${item.fingerprint}`);
    fingerprints.add(item.fingerprint);
  });
}

function validatePayload(value, expectedMission, expectedId) {
  assertKeys(value, ["schema", "mission", "status", "started_at", "updated_at", "snapshot", "gates", "milestones", "blockers", "resources", "outcome", "final_outcome"], "payload");
  if (value.schema !== PAYLOAD_SCHEMA) fail("payload has the wrong schema");
  assertKeys(value.mission, ["id", "title"], "payload.mission");
  if (value.mission.id !== expectedId || value.mission.title !== expectedMission) fail("payload mission does not match the requested mission");
  if (!new Set(["active", "closed"]).has(value.status)) fail("payload status is invalid");
  if (!Number.isFinite(Date.parse(value.started_at)) || !Number.isFinite(Date.parse(value.updated_at))) fail("payload timestamps are invalid");
  validateSnapshot(value.snapshot, "payload.snapshot");
  validateGates(value.gates, "payload.gates", { requireOne: true });
  if (!Array.isArray(value.milestones) || value.milestones.length === 0) fail("payload milestones must be non-empty");
  const ids = new Set(value.milestones.map((item) => item.id));
  if (ids.size !== value.milestones.length) fail("payload repeats milestone id");
  validateMilestoneHistory(value.milestones);
  validateBlockers(value.blockers, "payload.blockers");
  validateResources(value.resources, "payload.resources");
  if (value.status === "closed") {
    if (!OUTCOMES.has(value.outcome)) fail("closed payload outcome is invalid");
    validateText(value.final_outcome, "payload.final_outcome", MAX_SUMMARY);
  } else if (value.outcome !== undefined || value.final_outcome !== undefined) {
    fail("active payload cannot carry a final outcome");
  }
  return value;
}

function mergeById(current, patches, label, transition) {
  if (patches === undefined) return current;
  const next = current.map((item) => structuredClone(item));
  const index = new Map(next.map((item, i) => [item.id, i]));
  for (const patch of patches) {
    if (!index.has(patch.id)) {
      index.set(patch.id, next.length);
      next.push(patch);
      continue;
    }
    const old = next[index.get(patch.id)];
    transition(old, patch, label);
    next[index.get(patch.id)] = patch;
  }
  return next;
}

function milestoneId(at, milestones) {
  const base = milestonePrefix(at);
  let id = base;
  let suffix = 1;
  const used = new Set(milestones.map((item) => item.id));
  while (used.has(id)) id = `${base}-${String(++suffix).padStart(2, "0")}`;
  return id;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map((item) => stableJson(item)).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function updateFingerprint(update) {
  return crypto.createHash("sha256").update(stableJson(update), "utf8").digest("hex");
}

function applyUpdate(payload, update, command) {
  if (payload.status !== "active") fail("the mission is closed and cannot be updated");
  const now = new Date().toISOString();
  const fingerprint = updateFingerprint(update);
  if (payload.milestones.some((milestone) => milestone.fingerprint === fingerprint)) fail("duplicate logbook update refused");
  if (update.kind === "checkpoint") {
    const previous = Date.parse(payload.milestones[0].at);
    if (Date.now() - previous < CHECKPOINT_INTERVAL_MS) fail("quiet checkpoint refused before a six-hour meaningful interval");
  }
  const gates = mergeById(payload.gates, update.gates, "gate", (old, patch) => {
    if (old.label !== patch.label) fail(`gate ${old.id} cannot be renamed`);
    if (old.state === "passed" && patch.state !== "passed" && update.kind !== "diagnosed-failure") {
      fail(`passed gate ${old.id} can reopen only after a diagnosed failure`);
    }
  });
  const blockers = mergeById(payload.blockers, update.blockers, "blocker", (old, patch) => {
    if (old.summary !== patch.summary) fail(`blocker ${old.id} cannot be renamed`);
    if (old.state === "resolved" && patch.state !== "resolved") fail(`resolved blocker ${old.id} cannot reopen`);
  });
  const resources = mergeById(payload.resources, update.resources, "resource", (old, patch) => {
    if (old.label !== patch.label) fail(`resource ${old.id} cannot be renamed`);
  });
  if (gates.length > MAX_GATES || blockers.length > MAX_ITEMS || resources.length > MAX_ITEMS) fail("update exceeds the bounded item count");
  const milestone = {
    id: milestoneId(now, payload.milestones),
    at: now,
    kind: update.kind,
    title: update.title,
    summary: update.summary,
    evidence: update.evidence,
    fingerprint,
  };
  const next = {
    ...payload,
    updated_at: now,
    snapshot: update.snapshot,
    gates,
    blockers,
    resources,
    milestones: [milestone, ...payload.milestones],
  };
  if (command === "close") {
    if (update.outcome === "completed" && gates.some((gate) => gate.state !== "passed")) {
      fail("a completed mission cannot close while a completion gate is unfinished");
    }
    next.status = "closed";
    next.outcome = update.outcome;
    next.final_outcome = update.final_outcome;
  }
  validatePayload(next, payload.mission.title, payload.mission.id);
  return next;
}

function relativeFromHome(home, file) {
  const relative = path.relative(home, file);
  assertInside(home, file);
  return relative.split(path.sep).join("/");
}

function loadActive(home, root) {
  const file = path.join(root, "active.json");
  assertRegularOrAbsent(file, root);
  if (!fs.existsSync(file)) return undefined;
  const registration = validateRegistration(readJson(file, "active registration", home, root), home);
  const page = path.resolve(home, registration.page);
  assertInside(root, page);
  assertRegularOrAbsent(page, root);
  if (!fs.existsSync(page)) fail("active registration points to a missing mission page");
  const embedded = readEmbeddedPayload(page, home, root);
  const payload = validatePayload(embedded.payload, registration.mission, registration.mission_id);
  return { registration, page, payload };
}

function commandStart(home, mission, input) {
  const files = layout(home, mission);
  const release = acquireWriter(files);
  try {
    const active = loadActive(home, files.root);
    if (active) {
      if (active.payload.status === "closed") {
        removeConfinedFile(files.registration, files.home, files.root);
      } else if (active.registration.mission !== mission) {
        fail(`another mission is active: ${active.registration.mission}`);
      } else {
        process.stdout.write(`resumed: ${active.page}\nmission-id: ${files.missionId}\n`);
        return;
      }
    }
    ensureDirectory(files.missions, files.home);
    ensureDirectory(files.dir, files.home);
    const update = input ? validateUpdate(input, "start") : defaultStart(mission);
    const now = new Date().toISOString();
    const milestone = {
      id: milestoneId(now, []),
      at: now,
      kind: "start",
      title: update.title,
      summary: update.summary,
      evidence: update.evidence,
      fingerprint: updateFingerprint(update),
    };
    const payload = {
      schema: PAYLOAD_SCHEMA,
      mission: { id: files.missionId, title: mission },
      status: "active",
      started_at: now,
      updated_at: now,
      snapshot: update.snapshot,
      gates: update.gates || defaultStart(mission).gates,
      milestones: [milestone],
      blockers: update.blockers || [],
      resources: update.resources || [],
    };
    validatePayload(payload, mission, files.missionId);
    const template = process.env.FM_LOGBOOK_TEMPLATE || path.join(path.dirname(fileURLToPath(import.meta.url)), "assets", "logbook.html");
    if (!fs.existsSync(template) || fs.lstatSync(template).isSymbolicLink() || !fs.statSync(template).isFile()) fail(`logbook shell is missing: ${template}`);
    assertRegularOrAbsent(files.page, files.root);
    if (fs.existsSync(files.page)) fail(`mission page already exists without an active registration: ${files.page}`);
    writeAtomicContent(files.page, buildPage(template, payload), files.home, files.root);
    const registration = {
      schema: REGISTRATION_SCHEMA,
      mission_id: files.missionId,
      mission,
      page: relativeFromHome(home, files.page),
      started_at: now,
    };
    writeAtomicJson(files.registration, registration, files.home, files.root);
    process.stdout.write(`created: ${files.page}\nmission-id: ${files.missionId}\n`);
  } finally {
    release();
  }
}

function commandMutation(home, mission, input, command) {
  const files = layout(home, mission);
  const release = acquireWriter(files);
  try {
    const active = loadActive(home, files.root);
    if (!active) fail("no active logbook mission exists");
    if (active.registration.mission !== mission) fail(`active mission is ${active.registration.mission}`);
    const update = validateUpdate(input, command);
    if (command === "close" && active.payload.status === "closed") {
      assertRegularOrAbsent(files.registration, files.root);
      removeConfinedFile(files.registration, files.home, files.root);
      process.stdout.write(`closed: ${active.payload.milestones[0].id}\npage: ${active.page}\n`);
      return;
    }
    const next = applyUpdate(active.payload, update, command);
    writePagePayload(active.page, next, files.home, files.root);
    if (command === "close") {
      assertRegularOrAbsent(files.registration, files.root);
      removeConfinedFile(files.registration, files.home, files.root);
      process.stdout.write(`closed: ${next.milestones[0].id}\npage: ${active.page}\n`);
    } else {
      process.stdout.write(`updated: ${next.milestones[0].id}\npage: ${active.page}\n`);
    }
  } finally {
    release();
  }
}

function commandActive(home) {
  const root = path.join(home, "data", "logbook");
  if (!fs.existsSync(root)) {
    process.stdout.write("inactive\n");
    return;
  }
  assertDirectoryChain(root, home);
  const active = loadActive(home, root);
  if (!active || active.payload.status === "closed") {
    process.stdout.write("inactive\n");
    return;
  }
  process.stdout.write(`active: ${active.registration.mission}\npage: ${active.page}\nupdated: ${active.payload.updated_at}\nlatest: ${active.payload.milestones[0].id}\n`);
}

const { command, opts } = parseArgs(process.argv.slice(2));
try {
  const home = realHome();
  switch (command) {
    case "start": {
      if (!opts.mission) usage("--mission is required");
      const input = readInput(opts.input, false);
      commandStart(home, opts.mission, input);
      break;
    }
    case "update":
    case "close": {
      if (!opts.mission) usage("--mission is required");
      const input = readInput(opts.input, true);
      commandMutation(home, opts.mission, input, command);
      break;
    }
    case "active": {
      if (opts.mission || opts.input) usage("active accepts no arguments");
      commandActive(home);
      break;
    }
    case "path": {
      if (!opts.mission) usage("--mission is required");
      if (opts.input) usage("path does not accept --input");
      process.stdout.write(`${layout(home, opts.mission).page}\n`);
      break;
    }
    default:
      usage(`unknown command: ${command}`);
  }
} catch (error) {
  process.stderr.write(`logbook: ${error.message}\n`);
  process.exit(1);
}
