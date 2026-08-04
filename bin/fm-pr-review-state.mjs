#!/usr/bin/env node
// Durable state machine and authenticated GitHub boundary for automatic pull-request review.
//
// This file is the single owner of inventory normalization, feedback identity,
// queue transitions, exact-head generations, review-lane exclusion, response
// staging, and replay-safe delivery. bin/fm-pr-review.sh owns the public command
// surface and process-event registration.
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

const ITEM_SCHEMA = "fm-pr-review-item.v1";
const SNAPSHOT_SCHEMA = "fm-pr-review-snapshot.v1";
const CONTROL_SCHEMA = "fm-pr-review-control.v1";
const OPTOUT_SCHEMA = "fm-pr-review-opt-out.v1";
const EVENT_SCHEMA = "fm-pr-review-event.v1";
const PRIVATE_ROUTE_SCHEMA = "fm-pr-review-private-route.v1";
const PUBLICATION_GUARD_SCHEMA = "fm-pr-review-publication-guard.v1";
const SELF_REVIEW_PUBLICATION_METHODS = new Set(["comment-only-review", "fallback-comment"]);
const TERMINAL_FEEDBACK = new Set([
  "fixed-and-replied",
  "dismissed-and-replied",
  "duplicate-and-replied",
  "superseded-and-replied",
  "captain-decision-pending",
]);
const TERMINAL_REVIEW = new Set(["reviewed-clean", "reviewed-findings-corrected", "foreign-reviewed-and-commented"]);
const SHA_RE = /^[0-9a-f]{40}$/;
const LOGIN_RE = /^[A-Za-z0-9][A-Za-z0-9_.\-[\]]{0,99}$/;
const REPO_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const NOW = () => Number(process.env.FM_PR_REVIEW_NOW ?? Math.floor(Date.now() / 1000));

function die(message, code = 1) {
  process.stderr.write(`fm-pr-review: ${message}\n`);
  process.exit(code);
}

function integerSetting(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^[0-9]+$/.test(raw)) die(`${name} must be an integer between ${minimum} and ${maximum}`, 2);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    die(`${name} must be an integer between ${minimum} and ${maximum}`, 2);
  }
  return value;
}

const HOME = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || process.cwd();
const STATE = process.env.FM_STATE_OVERRIDE || join(HOME, "state");
const ROOT = join(STATE, "pr-review");
const ITEMS = join(ROOT, "items");
const BODIES = join(ROOT, "feedback-bodies");
const OPTOUTS = join(ROOT, "opt-outs");
const SNAPSHOT = join(ROOT, "snapshot.json");
const CONTROL = join(ROOT, "control.json");
const LANE = join(ROOT, "lane.json");
const INTERVAL = integerSetting("FM_PR_REVIEW_INTERVAL_SECS", 900, 60, 86400);
const MAX_REPOSITORIES = integerSetting("FM_PR_REVIEW_MAX_REPOSITORIES", 25, 1, 100);
const MAX_PULLS = integerSetting("FM_PR_REVIEW_MAX_PULLS", 50, 1, 200);
const PAGE_SIZE = integerSetting("FM_PR_REVIEW_PAGE_SIZE", 25, 1, 100);
const FEEDBACK_PAGE_SIZE = integerSetting("FM_PR_REVIEW_FEEDBACK_PAGE_SIZE", 5, 1, 10);
const MAX_PAGES = integerSetting("FM_PR_REVIEW_MAX_PAGES", 20, 1, 100);
const MAX_BODY_CHARS = integerSetting("FM_PR_REVIEW_MAX_BODY_CHARS", 100, 100, 1000);
const BODY_CHUNK_CHARS = 500;
const MAX_EXACT_BODY_CHARS = 65536;
const API_TIMEOUT_MS = integerSetting("FM_PR_REVIEW_API_TIMEOUT_MS", 7000, 1000, 15000);
const POLL_BUDGET_MS = integerSetting("FM_PR_REVIEW_POLL_BUDGET_MS", 120000, 5000, 180000);
const API_RETRIES = integerSetting("FM_PR_REVIEW_API_RETRIES", 1, 0, 2);
const WORST_CORE_READS = 2 + MAX_PULLS * (1 + 3 * (MAX_PAGES + 1));
const WORST_SEARCH_READS = 4 * Math.min(MAX_PAGES, Math.ceil(MAX_PULLS / PAGE_SIZE));
if (WORST_CORE_READS + 50 > 5000) die("configured pull and pagination bounds exceed one safe GitHub core-rate window", 2);
if (WORST_SEARCH_READS + 2 > 30) die("configured pull and pagination bounds exceed one safe GitHub search-rate window", 2);
const MIN_CORE_REMAINING = integerSetting("FM_PR_REVIEW_MIN_CORE_REMAINING", WORST_CORE_READS + 50, 1, 5000);
const MIN_SEARCH_REMAINING = integerSetting("FM_PR_REVIEW_MIN_SEARCH_REMAINING", WORST_SEARCH_READS + 2, 1, 30);
if (MIN_CORE_REMAINING < WORST_CORE_READS + 25) die("FM_PR_REVIEW_MIN_CORE_REMAINING cannot cover the configured inventory bound", 2);
if (MIN_SEARCH_REMAINING < WORST_SEARCH_READS + 1) die("FM_PR_REVIEW_MIN_SEARCH_REMAINING cannot cover the configured inventory bound", 2);
let deadline = 0;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalUrl(repo, number) {
  return `https://github.com/${repo}/pull/${number}`;
}

function parseUrl(raw) {
  const match = /^https:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99})\/pull\/([1-9][0-9]*)$/.exec(raw);
  if (!match || !REPO_RE.test(match[1])) die("pull-request URL must be canonical", 2);
  return { repo: match[1], number: Number(match[2]), url: raw };
}

function ensureDir(path) {
  if (existsSync(path)) {
    const st = lstatSync(path);
    if (!st.isDirectory() || st.isSymbolicLink()) die(`private state path is unsafe: ${path}`);
    if ((st.mode & 0o7777) !== 0o700) chmodSync(path, 0o700);
    return;
  }
  ensureDir(dirname(path));
  mkdirSync(path, { mode: 0o700 });
  const st = lstatSync(path);
  if (!st.isDirectory() || st.isSymbolicLink()) die(`private state path is unsafe: ${path}`);
}

function ensureState() {
  if (!existsSync(STATE)) mkdirSync(STATE, { recursive: true, mode: 0o700 });
  const stateStat = lstatSync(STATE);
  if (!stateStat.isDirectory() || stateStat.isSymbolicLink()) die(`private state path is unsafe: ${STATE}`);
  if ((stateStat.mode & 0o7777) !== 0o700) chmodSync(STATE, 0o700);
  ensureDir(ROOT);
  ensureDir(ITEMS);
  ensureDir(BODIES);
  ensureDir(OPTOUTS);
}

function privateFile(path, maximum = 16 * 1024 * 1024) {
  const st = lstatSync(path);
  if (!st.isFile() || st.isSymbolicLink() || st.nlink !== 1 || (st.mode & 0o7777) !== 0o600 || st.size > maximum) {
    die(`private state file is unsafe: ${path}`);
  }
}

function readJson(path, fallback = null, maximum) {
  if (!existsSync(path)) return fallback;
  privateFile(path, maximum);
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    die(`private state JSON is invalid: ${path}`);
  }
}

function atomicWrite(path, value) {
  ensureDir(dirname(path));
  const temp = join(dirname(path), `.fm-pr-review.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}`);
  const fd = openSync(temp, "wx", 0o600);
  try {
    writeFileSync(fd, typeof value === "string" ? value : `${JSON.stringify(value)}\n`, "utf8");
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  chmodSync(temp, 0o600);
  renameSync(temp, path);
  const dirFd = openSync(dirname(path), "r");
  try {
    fsyncSync(dirFd);
  } finally {
    closeSync(dirFd);
  }
}

function fileText(path, label) {
  if (typeof path !== "string" || path.length === 0) die(`${label} is required`, 2);
  let st;
  try {
    st = lstatSync(path);
  } catch {
    die(`${label} is unavailable or too large`, 2);
  }
  if (!st.isFile() || st.isSymbolicLink() || st.size <= 0 || st.size > 262144) die(`${label} is unavailable or too large`, 2);
  return readFileSync(path, "utf8").trim();
}

function validationEvidence(path, item, head) {
  const raw = fileText(path, "validation evidence file");
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    die("validation evidence is not valid JSON", 2);
  }
  if (!value || value.schema !== "fm-pr-review-validation.v1" || value.owner_task !== item.owner_task || value.head !== head
    || !["checks-green", "selected-lifecycle-passed"].includes(value.result)
    || typeof value.proof !== "string" || value.proof.length < 10 || value.proof.length > 1000) {
    die("validation evidence does not bind the owner, exact head, and selected lifecycle result", 2);
  }
  return value;
}

function validateSha(value, label = "head") {
  const normalized = String(value ?? "").toLowerCase();
  if (!SHA_RE.test(normalized)) die(`${label} is invalid`, 2);
  return normalized;
}

function itemPath(id) {
  if (!ID_RE.test(id)) die("item id is invalid", 2);
  return join(ITEMS, `${id}.json`);
}

function isTerminal(item) {
  return item.type === "feedback" ? TERMINAL_FEEDBACK.has(item.outcome) : TERMINAL_REVIEW.has(item.outcome);
}

function validateItem(item, path = "item") {
  if (!item || item.schema !== ITEM_SCHEMA || !ID_RE.test(item.id) || !["initial-review", "feedback"].includes(item.type)) {
    die(`${path} has an incompatible schema`);
  }
  if (!REPO_RE.test(item.repository) || !Number.isSafeInteger(item.number) || item.number < 1) die(`${path} has an invalid pull-request identity`);
  if (item.url !== canonicalUrl(item.repository, item.number) || !SHA_RE.test(item.head)) die(`${path} has an invalid exact head`);
  if (typeof item.authored !== "boolean" || !Number.isSafeInteger(item.generation) || item.generation < 1 || !Array.isArray(item.scopes)) {
    die(`${path} has an invalid generation or authorship`);
  }
  return item;
}

function readItem(id) {
  const path = itemPath(id);
  const item = readJson(path, null, 262144);
  if (!item) die(`item does not exist: ${id}`);
  return validateItem(item, id);
}

function writeItem(item) {
  validateItem(item);
  atomicWrite(itemPath(item.id), item);
}

function allItems() {
  ensureState();
  return readdirSync(ITEMS)
    .filter((name) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$/.test(name))
    .sort()
    .map((name) => validateItem(readJson(join(ITEMS, name), null, 262144), name));
}

function readControl() {
  const value = readJson(CONTROL, null, 65536);
  if (!value) return { schema: CONTROL_SCHEMA, next_poll: 0, failure: null, event_counter: 0, pending_event: null };
  if (value.schema !== CONTROL_SCHEMA || !Number.isSafeInteger(value.next_poll) || !Number.isSafeInteger(value.event_counter)) {
    die("poll control is invalid");
  }
  return value;
}

function writeControl(control) {
  atomicWrite(CONTROL, control);
}

function readSnapshot() {
  const value = readJson(SNAPSHOT, null);
  if (!value) return { schema: SNAPSHOT_SCHEMA, viewer: "", observed_at: 0, pulls: {} };
  if (value.schema !== SNAPSHOT_SCHEMA || typeof value.pulls !== "object" || !value.pulls) die("snapshot schema is invalid");
  return value;
}

function itemId(prefix, identity) {
  return `${prefix}-${sha256(identity).slice(0, 24)}`;
}

function readOptOuts() {
  const values = new Map();
  ensureState();
  for (const name of readdirSync(OPTOUTS).filter((entry) => entry.endsWith(".json")).sort()) {
    const record = readJson(join(OPTOUTS, name), null, 65536);
    if (!record || record.schema !== OPTOUT_SCHEMA) die(`opt-out record is invalid: ${name}`);
    const parsed = parseUrl(record.url);
    values.set(parsed.url, record);
  }
  return values;
}

function normalizedBody(value) {
  return String(value ?? "").replace(/\r\n/g, "\n").trim();
}

function simpleAcknowledgement(body) {
  const compact = body.toLowerCase().replace(/[.!\s]+/g, " ").trim();
  return /^(lgtm|approved|looks good|thanks|thank you|done|fixed|nice|ship it|👍|✅)$/.test(compact);
}

function transportOnly(actor, actorType, body) {
  if (actorType !== "Bot") return false;
  if (/<!--\s*(firstmate-transport|no-mistakes-transport)\b/i.test(body)) return true;
  const login = actor.toLowerCase();
  if (!["github-actions[bot]", "vercel[bot]", "netlify[bot]"].includes(login)) return false;
  return /^(?:deployment|preview|workflow|build|checks?)(?:\s|:|-).*(?:ready|passed|failed|status|url)/is.test(body) && !/```|\b(?:bug|incorrect|race|security|regression|should|must)\b/i.test(body);
}

function actionableBody(body) {
  return body.length > 0 && !simpleAcknowledgement(body);
}

function feedbackFor(pull, viewer) {
  const result = [];
  const push = (kind, raw, reviewHead = "") => {
    const body = normalizedBody(raw.body);
    const author = String(raw.user?.login ?? raw.author?.login ?? "").toLowerCase();
    const actorType = String(raw.user?.type ?? raw.author?.type ?? "User");
    if (!LOGIN_RE.test(author) || author === viewer || !actionableBody(body) || transportOnly(author, actorType, body)) return;
    const node = String(raw.node_id ?? raw.id ?? "");
    if (!node || node.length > 160) return;
    const updated = String(raw.updated_at ?? raw.submitted_at ?? raw.created_at ?? "");
    const version = sha256(`${kind}\u0000${node}\u0000${updated}\u0000${body}`).slice(0, 32);
    const parent = String(raw.in_reply_to_id ?? raw.id ?? "");
    result.push({
      key: `${kind}:${node}:${version}`,
      kind,
      node_id: node,
      numeric_id: Number.isSafeInteger(Number(raw.id)) ? Number(raw.id) : null,
      parent_thread_id: parent,
      author,
      actor_type: actorType,
      updated_at: updated,
      review_head: reviewHead && SHA_RE.test(String(reviewHead).toLowerCase()) ? String(reviewHead).toLowerCase() : null,
      url: String(raw.html_url ?? pull.url),
      body: [...body].slice(0, MAX_BODY_CHARS).join(""),
      body_truncated: Number(raw.body_length ?? [...body].length) > [...body].length,
    });
  };
  for (const review of pull.reviews ?? []) push("review-body", review, review.commit_id);
  for (const comment of pull.review_comments ?? []) push("inline-comment", comment, comment.commit_id || comment.original_commit_id);
  for (const comment of pull.conversation_comments ?? []) push("conversation-comment", comment);
  const seen = new Set();
  return result.filter((entry) => {
    if (seen.has(entry.key)) return false;
    seen.add(entry.key);
    return true;
  }).sort((a, b) => a.key.localeCompare(b.key));
}

function validateObservation(value) {
  if (!value || value.schema !== "fm-pr-review-observation.v1" || !LOGIN_RE.test(String(value.viewer ?? "")) || !Array.isArray(value.pulls)) {
    throw new PollError("github-schema", "GitHub returned an unsupported pull-request review inventory shape.", true);
  }
  const viewer = value.viewer.toLowerCase();
  if (value.pulls.length > MAX_PULLS) throw new PollError("inventory-bound", "Relevant open pull requests exceed the configured bounded inventory.", true);
  const repositories = new Set();
  const pulls = value.pulls.map((pull) => {
    if (!pull || !REPO_RE.test(String(pull.repository ?? "")) || !Number.isSafeInteger(pull.number) || pull.number < 1) {
      throw new PollError("github-schema", "GitHub returned an invalid pull-request identity.", true);
    }
    repositories.add(pull.repository);
    if (repositories.size > MAX_REPOSITORIES) throw new PollError("inventory-bound", "Relevant open pull requests span more repositories than the configured bound.", true);
    const url = canonicalUrl(pull.repository, pull.number);
    if (pull.url !== url || pull.state !== "open" || typeof pull.draft !== "boolean") throw new PollError("github-schema", "GitHub returned an unsupported pull-request lifecycle shape.", true);
    const head = validateSha(pull.head, "observed head");
    const author = String(pull.author ?? "").toLowerCase();
    if (!LOGIN_RE.test(author) || !Array.isArray(pull.scopes) || pull.scopes.length === 0) throw new PollError("github-schema", "GitHub returned an invalid participant shape.", true);
    return {
      ...pull,
      url,
      head,
      author,
      authored: author === viewer,
      scopes: [...new Set(pull.scopes)].sort(),
      reviews: Array.isArray(pull.reviews) ? pull.reviews : [],
      review_comments: Array.isArray(pull.review_comments) ? pull.review_comments : [],
      conversation_comments: Array.isArray(pull.conversation_comments) ? pull.conversation_comments : [],
    };
  });
  return { viewer, observed_at: Number(value.observed_at ?? NOW()), pulls: pulls.sort((a, b) => a.url.localeCompare(b.url)) };
}

function findOwningTask(url) {
  if (!existsSync(STATE)) return null;
  const matches = [];
  for (const name of readdirSync(STATE).filter((entry) => entry.endsWith(".meta")).sort()) {
    const id = name.slice(0, -5);
    if (!ID_RE.test(id)) continue;
    const path = join(STATE, name);
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink() || st.size > 65536) continue;
    const lines = readFileSync(path, "utf8").split("\n");
    if (lines.filter((line) => line === `pr=${url}`).length === 1) matches.push(id);
  }
  return matches.length === 1 ? matches[0] : null;
}

function newReviewItem(pull, now) {
  const id = itemId("review", `${pull.url}\u0000${pull.head}`);
  return {
    schema: ITEM_SCHEMA,
    id,
    type: "initial-review",
    repository: pull.repository,
    number: pull.number,
    url: pull.url,
    head: pull.head,
    authored: pull.authored,
    scopes: pull.scopes,
    owning_task: findOwningTask(pull.url),
    generation: 1,
    state: "pending",
    outcome: null,
    created_at: now,
    updated_at: now,
    retry_count: 0,
    evidence: null,
    response: null,
    review_outcome: null,
    independent_review: false,
    private_route: null,
    publication_guard: null,
  };
}

function newFeedbackItem(pull, feedback, now) {
  const id = itemId("feedback", `${pull.url}\u0000${feedback.key}`);
  return {
    schema: ITEM_SCHEMA,
    id,
    type: "feedback",
    repository: pull.repository,
    number: pull.number,
    url: pull.url,
    head: pull.head,
    authored: true,
    scopes: pull.scopes,
    owning_task: findOwningTask(pull.url),
    generation: 1,
    state: "pending",
    outcome: null,
    created_at: now,
    updated_at: now,
    retry_count: 0,
    evidence: null,
    response: null,
    feedback,
  };
}

function reconcileObservation(observation) {
  ensureState();
  const previous = readSnapshot();
  const optOuts = readOptOuts();
  const next = { schema: SNAPSHOT_SCHEMA, viewer: observation.viewer, observed_at: observation.observed_at, pulls: {} };
  let changed = 0;
  const currentItems = new Map(allItems().map((item) => [item.id, item]));
  for (const pull of observation.pulls) {
    const prior = previous.pulls[pull.url] ?? { covered_head: null, covered_feedback: [] };
    const optedOut = optOuts.has(pull.url);
    const feedback = pull.authored ? feedbackFor(pull, observation.viewer) : [];
    const feedbackKeys = feedback.map((entry) => entry.key);
    let coveredHead = prior.covered_head ?? null;
    let coveredFeedback = Array.isArray(prior.covered_feedback) ? prior.covered_feedback : [];
    if (!optedOut) {
      if (coveredHead !== pull.head) {
        const inProgress = [...currentItems.values()].filter((item) =>
          item.type === "initial-review" && item.url === pull.url && !isTerminal(item) && item.state !== "opted-out",
        );
        if (inProgress.length > 1) throw new PollError("private-state", `More than one nonterminal review owns ${pull.url}.`, true);
        if (inProgress.length === 1) {
          const item = inProgress[0];
          if (item.head !== pull.head) {
            item.head = pull.head;
            item.generation += 1;
            item.state = "pending";
            item.outcome = null;
            item.response = null;
            item.evidence = null;
            item.review_outcome = null;
            item.independent_review = false;
            item.private_route = null;
            item.publication_guard = null;
            delete item.validation;
            item.updated_at = observation.observed_at;
            writeItem(item);
            changed += 1;
          }
        } else {
          const item = newReviewItem(pull, observation.observed_at);
          if (!existsSync(itemPath(item.id))) {
            writeItem(item);
            currentItems.set(item.id, item);
            changed += 1;
          }
        }
        coveredHead = pull.head;
      }
      const coveredSet = new Set(coveredFeedback);
      for (const entry of feedback) {
        const id = itemId("feedback", `${pull.url}\u0000${entry.key}`);
        const existing = currentItems.get(id);
        if (!coveredSet.has(entry.key) && !existing) {
          const item = newFeedbackItem(pull, entry, observation.observed_at);
          writeItem(item);
          currentItems.set(item.id, item);
          changed += 1;
        } else if (existing && !isTerminal(existing) && existing.head !== pull.head && existing.state !== "opted-out") {
          existing.head = pull.head;
          existing.generation += 1;
          existing.state = "pending";
          existing.outcome = null;
          existing.updated_at = observation.observed_at;
          existing.response = null;
          existing.evidence = null;
          delete existing.validation;
          writeItem(existing);
          changed += 1;
        }
        coveredSet.add(entry.key);
      }
      coveredFeedback = [...coveredSet].sort();
    }
    next.pulls[pull.url] = {
      repository: pull.repository,
      number: pull.number,
      head: pull.head,
      authored: pull.authored,
      draft: pull.draft,
      scopes: pull.scopes,
      feedback: feedbackKeys,
      covered_head: coveredHead,
      covered_feedback: coveredFeedback,
      opted_out: optedOut,
    };
  }
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-items") process.exit(99);
  atomicWrite(SNAPSHOT, next);
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-snapshot") process.exit(99);
  return changed;
}

class PollError extends Error {
  constructor(category, message, immediate = false, retryAt = 0) {
    super(message);
    this.category = category;
    this.immediate = immediate;
    this.retryAt = retryAt;
  }
}

function decodeTsvField(value) {
  let decoded = "";
  for (let index = 0; index < value.length; index += 1) {
    if (value[index] !== "\\") {
      decoded += value[index];
      continue;
    }
    const escaped = value[++index];
    if (escaped === undefined) throw new PollError("github-schema", "gh-axi returned a truncated TSV field.", true);
    if (escaped === "\\") decoded += "\\";
    else if (escaped === "t") decoded += "\t";
    else if (escaped === "n") decoded += "\n";
    else if (escaped === "r") decoded += "\r";
    else throw new PollError("github-schema", "gh-axi returned an unsupported TSV escape.", true);
  }
  return decoded;
}

function parseAxiBody(output) {
  const lines = output.split(/\r?\n/);
  if (!lines.includes("  truncated: false")) throw new PollError("response-bound", "GitHub response exceeded the bounded gh-axi transport.", true);
  const bodyLines = lines.filter((line) => line.startsWith("  body: "));
  if (bodyLines.length !== 1) throw new PollError("github-schema", "gh-axi returned an unsupported response envelope.", true);
  const encoded = bodyLines[0].slice("  body: ".length);
  let body;
  try {
    body = JSON.parse(encoded);
  } catch {
    throw new PollError("github-schema", "gh-axi returned an unsupported encoded body.", true);
  }
  const separator = body.indexOf("\t");
  if (separator < 0 || body.slice(0, separator) !== "fm-pr-review-safe-v1") throw new PollError("github-schema", "gh-axi response marker is invalid.", true);
  try {
    return JSON.parse(decodeTsvField(body.slice(separator + 1)));
  } catch {
    throw new PollError("github-schema", "GitHub selected response is invalid JSON.", true);
  }
}

function apiJson(filter, args, write = false) {
  const wrapped = `["fm-pr-review-safe-v1",((${filter})|tojson)]|@tsv`;
  const attempts = write ? 1 : API_RETRIES + 1;
  let last = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const remaining = deadline ? deadline - Date.now() : API_TIMEOUT_MS;
    if (remaining < 1000) throw new PollError("execution-bound", "Pull-request review inventory exceeded its execution-time bound.", true);
    const result = spawnSync("gh-axi", ["api", ...args, "--jq", wrapped], {
      encoding: "utf8",
      timeout: Math.min(API_TIMEOUT_MS, remaining),
      maxBuffer: 524288,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (!result.error && result.status === 0) return parseAxiBody(result.stdout);
    last = result;
  }
  const detail = String(last?.stderr ?? "");
  const auth = /auth|login|credential|401|403/i.test(detail);
  throw new PollError(auth ? "authentication" : "github-read", auth ? "GitHub authentication is unavailable for automatic pull-request review." : "GitHub pull-request review inventory reads are failing.");
}

function requireCoreHeadroom(required) {
  const rate = apiJson("{core:.resources.core}", ["/rate_limit"]);
  const remaining = Number(rate.core?.remaining);
  if (!Number.isFinite(remaining) || remaining < required) {
    throw new PollError("rate-limit", "GitHub core-rate headroom is too low for this bounded pull-request review operation.");
  }
}

function readPaged(path, filter) {
  const all = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const separator = path.includes("?") ? "&" : "?";
    const rows = apiJson(filter, [`${path}${separator}per_page=${FEEDBACK_PAGE_SIZE}&page=${page}`]);
    if (!Array.isArray(rows) || rows.length > FEEDBACK_PAGE_SIZE) throw new PollError("github-schema", "GitHub pagination returned an invalid page.", true);
    all.push(...rows);
    if (rows.length < FEEDBACK_PAGE_SIZE) return all;
  }
  const separator = path.includes("?") ? "&" : "?";
  const probe = apiJson("[.[]|.id]", [`${path}${separator}per_page=${FEEDBACK_PAGE_SIZE}&page=${MAX_PAGES + 1}`]);
  if (Array.isArray(probe) && probe.length === 0) return all;
  throw new PollError("pagination-bound", `GitHub pagination exceeded ${MAX_PAGES} pages without silently dropping eligible records.`, true);
}

function searchScope(viewer, qualifier) {
  const query = encodeURIComponent(`is:pr is:open ${qualifier}:@me`);
  const rows = [];
  let total = null;
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const value = apiJson("{total:.total_count,items:[.items[]|{repository_url,number}]}", [`/search/issues?q=${query}&per_page=${PAGE_SIZE}&page=${page}`]);
    if (!value || !Array.isArray(value.items) || value.items.length > PAGE_SIZE || !Number.isSafeInteger(value.total)) {
      throw new PollError("github-schema", "GitHub search returned an invalid page.", true);
    }
    total = value.total;
    if (total > MAX_PULLS) throw new PollError("inventory-bound", `The ${qualifier} pull-request scope exceeds the configured pull-request bound.`, true);
    rows.push(...value.items);
    if (rows.length >= total || value.items.length < PAGE_SIZE) return rows;
  }
  if (rows.length < total) throw new PollError("pagination-bound", `The ${qualifier} pull-request scope exceeded bounded pagination.`, true);
  return rows;
}

function selectedBodyFilter() {
  return `{id,node_id,body:((.body//"")|.[0:${MAX_BODY_CHARS}]),body_length:((.body//"")|length),state,commit_id,original_commit_id,in_reply_to_id,submitted_at,created_at,updated_at,html_url,user:(if .user==null then null else {login:.user.login,type:.user.type} end)}`;
}

function liveObservation() {
  deadline = Date.now() + POLL_BUDGET_MS;
  const user = apiJson("{login:.login}", ["/user"]);
  const viewer = String(user.login ?? "").toLowerCase();
  if (!LOGIN_RE.test(viewer)) throw new PollError("authentication", "GitHub authentication did not identify a valid work account.", true);
  const rate = apiJson("{core:.resources.core,search:.resources.search}", ["/rate_limit"]);
  const core = Number(rate.core?.remaining);
  const search = Number(rate.search?.remaining);
  const reset = Math.max(Number(rate.core?.reset ?? 0), Number(rate.search?.reset ?? 0));
  if (!Number.isFinite(core) || !Number.isFinite(search)) throw new PollError("rate-limit", "GitHub rate-limit state is unreadable.", true);
  if (core < MIN_CORE_REMAINING || search < MIN_SEARCH_REMAINING) {
    throw new PollError("rate-limit", "GitHub rate-limit headroom is too low for the bounded pull-request inventory.", true, reset + 5);
  }
  const scopes = new Map();
  const scopeQueries = [
    ["authored", "author"],
    ["review-requested", "review-requested"],
    ["assigned", "assignee"],
    ["materially-participating", "involves"],
  ];
  for (const [scope, qualifier] of scopeQueries) {
    for (const row of searchScope(viewer, qualifier)) {
      const match = /^https:\/\/api\.github\.com\/repos\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)$/.exec(String(row.repository_url ?? ""));
      if (!match || !REPO_RE.test(match[1]) || !Number.isSafeInteger(row.number) || row.number < 1) throw new PollError("github-schema", "GitHub search returned an invalid pull request.", true);
      const key = `${match[1]}#${row.number}`;
      if (!scopes.has(key)) scopes.set(key, { repository: match[1], number: row.number, scopes: new Set() });
      scopes.get(key).scopes.add(scope);
    }
  }
  if (scopes.size > MAX_PULLS) throw new PollError("inventory-bound", "Relevant open pull requests exceed the configured bounded inventory.", true);
  const repositories = new Set([...scopes.values()].map((entry) => entry.repository));
  if (repositories.size > MAX_REPOSITORIES) throw new PollError("inventory-bound", "Relevant open pull requests span more repositories than the configured bound.", true);
  const pulls = [];
  for (const candidate of [...scopes.values()].sort((a, b) => `${a.repository}#${a.number}`.localeCompare(`${b.repository}#${b.number}`))) {
    const detail = apiJson("{number,html_url,state,draft,head:.head.sha,author:.user.login,requested_reviewers:[.requested_reviewers[].login],assignees:[.assignees[].login]}", [`/repos/${candidate.repository}/pulls/${candidate.number}`]);
    const authored = String(detail.author ?? "").toLowerCase() === viewer;
    if (authored) candidate.scopes.add("authored");
    if ((detail.requested_reviewers ?? []).some((login) => String(login).toLowerCase() === viewer)) candidate.scopes.add("review-requested");
    if ((detail.assignees ?? []).some((login) => String(login).toLowerCase() === viewer)) candidate.scopes.add("assigned");
    const reviews = authored ? readPaged(`/repos/${candidate.repository}/pulls/${candidate.number}/reviews`, `[.[]|${selectedBodyFilter()}]`) : [];
    const reviewComments = authored ? readPaged(`/repos/${candidate.repository}/pulls/${candidate.number}/comments`, `[.[]|${selectedBodyFilter()}]`) : [];
    const conversationComments = authored ? readPaged(`/repos/${candidate.repository}/issues/${candidate.number}/comments`, `[.[]|${selectedBodyFilter()}]`) : [];
    pulls.push({
      repository: candidate.repository,
      number: candidate.number,
      url: detail.html_url,
      state: String(detail.state ?? "").toLowerCase(),
      draft: Boolean(detail.draft),
      head: detail.head,
      author: detail.author,
      scopes: [...candidate.scopes],
      reviews,
      review_comments: reviewComments,
      conversation_comments: conversationComments,
    });
  }
  return { schema: "fm-pr-review-observation.v1", viewer, observed_at: NOW(), pulls };
}

function fixtureObservation(path) {
  const st = lstatSync(path);
  if (!st.isFile() || st.isSymbolicLink() || st.size <= 0 || st.size > 16 * 1024 * 1024) throw new PollError("fixture", "Observation fixture is unavailable.", true);
  return JSON.parse(readFileSync(path, "utf8"));
}

function actionableCounts() {
  const items = allItems();
  const lane = readJson(LANE, null, 65536);
  const pending = items.filter((item) => item.state === "pending").length;
  const responses = items.filter((item) => item.state === "response-pending").length;
  return { pending, responses, lane: lane?.item_id ?? null };
}

function makeEvent(control, changed, category = "inventory", message = "") {
  const counts = actionableCounts();
  if (changed === 0 && counts.responses === 0 && !(counts.pending > 0 && !counts.lane)) return null;
  const counter = control.event_counter + 1;
  const id = `${NOW()}-${sha256(`${counter}:${changed}:${counts.pending}:${counts.responses}:${category}`).slice(0, 16)}`;
  return { schema: EVENT_SCHEMA, event_id: id, category, changed, pending: counts.pending, response_pending: counts.responses, message };
}

function emitEvent(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function poll() {
  ensureState();
  const control = readControl();
  const now = NOW();
  if (control.pending_event) {
    emitEvent(control.pending_event);
    return;
  }
  const force = process.argv.includes("--force") || process.env.FM_PR_REVIEW_FORCE_POLL === "1";
  if (!force && now < control.next_poll) process.exit(3);
  try {
    const raw = process.env.FM_PR_REVIEW_OBSERVATION_FILE ? fixtureObservation(process.env.FM_PR_REVIEW_OBSERVATION_FILE) : liveObservation();
    const observation = validateObservation(raw);
    const changed = reconcileObservation(observation);
    const event = makeEvent(control, changed);
    const next = {
      schema: CONTROL_SCHEMA,
      next_poll: now + INTERVAL,
      failure: null,
      event_counter: event ? control.event_counter + 1 : control.event_counter,
      pending_event: event,
    };
    writeControl(next);
    if (!event) process.exit(3);
    emitEvent(event);
  } catch (error) {
    const failure = error instanceof PollError ? error : new PollError("unexpected", "Automatic pull-request review inventory failed safely.");
    const fingerprint = sha256(`${failure.category}:${failure.message}`);
    const prior = control.failure;
    const count = prior?.fingerprint === fingerprint ? Math.min((prior.count ?? 0) + 1, 1000) : 1;
    const notified = prior?.fingerprint === fingerprint ? Boolean(prior.notified) : false;
    const backoff = Math.min(900, 60 * 2 ** Math.min(count - 1, 4));
    const nextPoll = failure.retryAt > now ? failure.retryAt : now + backoff;
    if (notified) {
      writeControl({
        schema: CONTROL_SCHEMA,
        next_poll: nextPoll,
        failure: { category: failure.category, message: failure.message, fingerprint, count, notified: true },
        event_counter: control.event_counter,
        pending_event: null,
      });
      process.exit(3);
    }
    const event = makeEvent(control, 1, failure.category, failure.message);
    const next = {
      schema: CONTROL_SCHEMA,
      next_poll: nextPoll,
      failure: { category: failure.category, message: failure.message, fingerprint, count, notified: true },
      event_counter: control.event_counter + 1,
      pending_event: event,
    };
    writeControl(next);
    emitEvent(event);
  }
}

function currentHead(item) {
  if (process.env.FM_PR_REVIEW_CURRENT_HEAD) return validateSha(process.env.FM_PR_REVIEW_CURRENT_HEAD, "current head override");
  deadline = Date.now() + API_TIMEOUT_MS * (API_RETRIES + 1);
  const detail = apiJson("{head:.head.sha,state:.state}", [`/repos/${item.repository}/pulls/${item.number}`]);
  if (String(detail.state).toLowerCase() !== "open") die("pull request is no longer open");
  return validateSha(detail.head, "current GitHub head");
}

function laneRead() {
  const lane = readJson(LANE, null, 65536);
  if (!lane) return null;
  if (lane.schema !== "fm-pr-review-lane.v1" || !ID_RE.test(lane.item_id) || !ID_RE.test(lane.owner_task)) die("review lane record is invalid");
  return lane;
}

function laneRelease(id) {
  const lane = laneRead();
  if (lane?.item_id === id) rmSync(LANE, { force: true });
}

function parseFlags(args) {
  const result = { _: [] };
  for (let i = 0; i < args.length; i += 1) {
    if (!args[i].startsWith("--")) result._.push(args[i]);
    else {
      const key = args[i].slice(2).replace(/-/g, "_");
      if (Object.hasOwn(result, key)) die(`--${key.replace(/_/g, "-")} was repeated`, 2);
      if (!args[i + 1] || args[i + 1].startsWith("--")) die(`--${key.replace(/_/g, "-")} needs a value`, 2);
      result[key] = args[++i];
    }
  }
  return result;
}

function requireOnly(flags, allowed, positional = 1) {
  if (flags._.length !== positional) die("command has an invalid positional argument count", 2);
  for (const key of Object.keys(flags)) {
    if (key !== "_" && !allowed.includes(key)) die(`unsupported flag: --${key.replace(/_/g, "-")}`, 2);
  }
}

function claim(args) {
  const flags = parseFlags(args);
  requireOnly(flags, ["owner_task"]);
  const id = flags._[0];
  const owner = flags.owner_task;
  if (!ID_RE.test(String(id ?? "")) || !ID_RE.test(String(owner ?? ""))) die("claim requires a safe item id and --owner-task", 2);
  const item = readItem(id);
  if (isTerminal(item) || item.state === "captain-decision-pending" || item.state === "opted-out") die("item is not claimable", 4);
  const lane = laneRead();
  if (lane && lane.item_id !== id) die(`review lane is occupied by ${lane.item_id}`, 4);
  if (item.state === "claimed" && item.owner_task && item.owner_task !== owner) die(`item is already owned by ${item.owner_task}`, 4);
  item.state = "claimed";
  item.owner_task = owner;
  item.updated_at = NOW();
  writeItem(item);
  atomicWrite(LANE, { schema: "fm-pr-review-lane.v1", item_id: id, owner_task: owner, generation: item.generation, claimed_at: NOW() });
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-claim") process.exit(99);
  process.stdout.write(`${JSON.stringify({ item_id: id, owner_task: owner, head: item.head, generation: item.generation, replay: Boolean(lane) })}\n`);
}

function verifyGeneration(item, flags, allowedStates = ["claimed"]) {
  const head = validateSha(flags.head, "resolved head");
  const generation = Number(flags.generation);
  if (!Number.isSafeInteger(generation) || generation < 1) die("--generation is invalid", 2);
  if (!allowedStates.includes(item.state) || item.head !== head || item.generation !== generation) {
    die("item claim no longer matches the exact head generation", 5);
  }
  const current = currentHead(item);
  if (current !== head) {
    item.head = current;
    item.generation += 1;
    item.state = "pending";
    item.outcome = null;
    item.response = null;
    item.evidence = null;
    if (item.type === "initial-review") {
      item.review_outcome = null;
      item.independent_review = false;
      item.private_route = null;
      item.publication_guard = null;
    }
    delete item.validation;
    item.updated_at = NOW();
    writeItem(item);
    process.stdout.write(`${JSON.stringify({ requeued: item.id, head: current, generation: item.generation })}\n`);
    process.exit(5);
  }
  return head;
}

function feedbackEndpoint(item) {
  const id = item.feedback?.numeric_id;
  if (!Number.isSafeInteger(id) || id < 1) die("feedback has no bounded GitHub numeric identity", 4);
  if (item.feedback.kind === "review-body") return `/repos/${item.repository}/pulls/${item.number}/reviews/${id}`;
  if (item.feedback.kind === "inline-comment") return `/repos/${item.repository}/pulls/comments/${id}`;
  if (item.feedback.kind === "conversation-comment") return `/repos/${item.repository}/issues/comments/${id}`;
  die("feedback kind cannot be fetched", 4);
}

function fetchFeedback(args) {
  const flags = parseFlags(args);
  requireOnly(flags, []);
  const item = readItem(flags._[0]);
  if (item.type !== "feedback") die("item is not feedback", 2);
  const lane = laneRead();
  if (item.state !== "claimed" || lane?.item_id !== item.id || lane.owner_task !== item.owner_task) {
    die("feedback must own the active review lane before its exact body is fetched", 4);
  }
  const endpoint = feedbackEndpoint(item);
  deadline = Date.now() + POLL_BUDGET_MS;
  requireCoreHeadroom(Math.ceil(MAX_EXACT_BODY_CHARS / BODY_CHUNK_CHARS) + 2);
  const chunks = [];
  let start = 0;
  let total = null;
  while (total === null || start < total) {
    const end = start + BODY_CHUNK_CHARS;
    const filter = `{id,node_id,body_length:((.body//"")|length),chunk:((.body//"")[${start}:${end}]),submitted_at,created_at,updated_at}`;
    const value = apiJson(filter, [endpoint]);
    const observedId = Number(value?.id);
    const observedNode = String(value?.node_id ?? value?.id ?? "");
    const observedUpdated = String(value?.updated_at ?? value?.submitted_at ?? value?.created_at ?? "");
    const length = Number(value?.body_length);
    if (observedId !== item.feedback.numeric_id || observedNode !== item.feedback.node_id || observedUpdated !== item.feedback.updated_at) {
      die("feedback changed while its complete body was being fetched; poll and adjudicate the new identity", 5);
    }
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_EXACT_BODY_CHARS || (total !== null && length !== total)) {
      die("feedback body exceeds the bounded exact-body reader", 4);
    }
    total = length;
    const chunk = String(value.chunk ?? "");
    const consumed = [...chunk].length;
    if (start < total && (consumed < 1 || consumed > BODY_CHUNK_CHARS || consumed > total - start)) die("GitHub returned an invalid feedback body chunk", 4);
    chunks.push(chunk);
    start += consumed;
  }
  const body = normalizedBody(chunks.join(""));
  if (normalizedBody([...body].slice(0, MAX_BODY_CHARS).join("")) !== item.feedback.body) {
    die("feedback prefix changed while its complete body was being fetched; poll before adjudication", 5);
  }
  const recordPath = join(BODIES, `${item.id}.json`);
  const record = {
    schema: "fm-pr-review-feedback-body.v1",
    item_id: item.id,
    feedback_key: item.feedback.key,
    node_id: item.feedback.node_id,
    updated_at: item.feedback.updated_at,
    body,
    body_sha256: sha256(body),
    fetched_at: NOW(),
  };
  atomicWrite(recordPath, record);
  item.complete_body = { path: recordPath, sha256: record.body_sha256, fetched_at: record.fetched_at };
  item.updated_at = NOW();
  writeItem(item);
  process.stdout.write(`${JSON.stringify(item.complete_body)}\n`);
}

function requireCompleteFeedbackBody(item) {
  if (!item.feedback?.body_truncated) return;
  const expectedPath = join(BODIES, `${item.id}.json`);
  const record = readJson(expectedPath, null, 1048576);
  if (!record || record.schema !== "fm-pr-review-feedback-body.v1"
    || record.item_id !== item.id || record.feedback_key !== item.feedback.key
    || record.node_id !== item.feedback.node_id || record.updated_at !== item.feedback.updated_at
    || typeof record.body !== "string" || record.body_sha256 !== sha256(record.body)
    || item.complete_body?.path !== expectedPath || item.complete_body.sha256 !== record.body_sha256) {
    die("complete exact-node feedback body is required before adjudication", 4);
  }
}

function publicResponse(body, head) {
  if (body.length < 20 || body.length > 7000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(body)) die("response body is invalid or outside its bound", 2);
  if (!body.includes(head)) die("response must name the exact current head", 2);
  if (/\/(?:Users|home|var\/folders)\/|\b(?:worktree|watcher|harness|runtime backend|task id|state\/pr-review|\.no-mistakes)\b/i.test(body)) {
    die("response contains a private path or internal operational term", 2);
  }
}

function boundResponse(item, method, body, head) {
  const marker = `<!-- fm-pr-response:${sha256(`${item.id}\u0000${item.generation}\u0000${method}\u0000${head}\u0000${body}`).slice(0, 32)} -->`;
  return { state: "pending", method, marker, body: `${marker}\n${body}`, head, attempt_count: 0, github_node: null };
}

function resolveFeedback(args) {
  const flags = parseFlags(args);
  requireOnly(flags, ["head", "generation", "verdict", "evidence_file", "validation_evidence", "reply_file"]);
  const item = readItem(flags._[0]);
  if (item.type !== "feedback") die("item is not feedback", 2);
  requireCompleteFeedbackBody(item);
  const head = verifyGeneration(item, flags);
  const verdict = flags.verdict;
  const mapping = {
    fixed: "fixed-and-replied",
    dismissed: "dismissed-and-replied",
    duplicate: "duplicate-and-replied",
    superseded: "superseded-and-replied",
    "captain-decision-pending": "captain-decision-pending",
  };
  if (!mapping[verdict]) die("--verdict is invalid", 2);
  const evidence = fileText(flags.evidence_file, "evidence file");
  if (verdict === "fixed") item.validation = validationEvidence(flags.validation_evidence, item, head);
  else if (flags.validation_evidence) die("validation evidence applies only to a fixed verdict", 2);
  item.evidence = evidence;
  item.outcome = mapping[verdict];
  item.updated_at = NOW();
  if (verdict === "captain-decision-pending") {
    if (flags.reply_file) die("captain-decision-pending cannot stage an outward response", 2);
    item.state = "captain-decision-pending";
    writeItem(item);
    laneRelease(item.id);
    process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: item.outcome, response: "withheld" })}\n`);
    return;
  }
  const body = fileText(flags.reply_file, "reply file");
  publicResponse(body, head);
  const method = item.feedback.kind === "inline-comment" ? "inline-reply" : "issue-comment";
  item.response = boundResponse(item, method, body, head);
  item.state = "response-pending";
  writeItem(item);
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-response-stage") process.exit(99);
  process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: item.outcome, response: "pending" })}\n`);
}

function stagePrivateFindings(item, source) {
  item.authored = true;
  item.independent_review = false;
  item.outcome = null;
  item.response = null;
  item.state = "private-findings-pending";
  item.private_route = {
    schema: PRIVATE_ROUTE_SCHEMA,
    status: "pending",
    owner_task: item.owning_task,
    review_task: item.owner_task,
    head: item.head,
    generation: item.generation,
    findings_sha256: sha256(item.evidence),
    source,
    routed_at: NOW(),
  };
}

function completeReview(args) {
  const flags = parseFlags(args);
  requireOnly(flags, ["head", "generation", "outcome", "evidence_file", "reply_file"]);
  const item = readItem(flags._[0]);
  if (item.type !== "initial-review") die("item is not an initial review", 2);
  const head = verifyGeneration(item, flags, item.authored ? ["claimed", "private-findings-pending"] : ["claimed"]);
  const outcome = flags.outcome;
  if (!["clean", "findings", "findings-corrected"].includes(outcome)) die("--outcome must be clean, findings, or findings-corrected", 2);
  item.evidence = fileText(flags.evidence_file, "review evidence file");
  item.review_outcome = outcome;
  item.updated_at = NOW();
  if (item.authored) {
    if (flags.reply_file) die("a fleet-authored pull request never receives its own review response", 2);
    item.independent_review = false;
    if (outcome === "findings") {
      stagePrivateFindings(item, "authored-review");
      writeItem(item);
      process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: "private-findings-routed", head, owner_task: item.owning_task })}\n`);
      return;
    }
    if (outcome === "findings-corrected" && item.private_route?.status === "pending") {
      item.private_route.status = "corrected";
      item.private_route.corrected_at = NOW();
      item.private_route.correction_evidence_sha256 = sha256(item.evidence);
    }
    item.outcome = outcome === "clean" ? "reviewed-clean" : "reviewed-findings-corrected";
    item.state = "terminal";
    item.response = null;
    writeItem(item);
    laneRelease(item.id);
    process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: item.outcome, head, independent_review: false })}\n`);
    return;
  }
  if (outcome === "findings-corrected") die("a foreign comment-only review cannot claim branch corrections", 4);
  const body = fileText(flags.reply_file, "comment-only review file");
  publicResponse(body, head);
  item.independent_review = false;
  item.response = boundResponse(item, "comment-only-review", body, head);
  item.state = "response-pending";
  item.outcome = "foreign-reviewed-and-commented";
  writeItem(item);
  process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: item.outcome, response: "pending" })}\n`);
}

function pagedForDelivery(item, kind) {
  deadline = Date.now() + POLL_BUDGET_MS;
  const filter = `[.[]|${selectedBodyFilter()}]`;
  if (kind === "reviews") return readPaged(`/repos/${item.repository}/pulls/${item.number}/reviews`, filter);
  if (kind === "inline") return readPaged(`/repos/${item.repository}/pulls/${item.number}/comments`, filter);
  return readPaged(`/repos/${item.repository}/issues/${item.number}/comments`, filter);
}

function existingResponse(item, viewer) {
  const response = item.response;
  if (response.method === "comment-only-review") {
    return pagedForDelivery(item, "reviews").find((entry) => String(entry.user?.login ?? "").toLowerCase() === viewer && normalizedBody(entry.body).includes(response.marker) && String(entry.commit_id ?? "").toLowerCase() === response.head);
  }
  if (response.method === "inline-reply") {
    const parent = String(item.feedback.parent_thread_id);
    return pagedForDelivery(item, "inline").find((entry) => String(entry.user?.login ?? "").toLowerCase() === viewer && normalizedBody(entry.body).includes(response.marker) && String(entry.in_reply_to_id ?? "") === parent);
  }
  return pagedForDelivery(item, "issue").find((entry) => String(entry.user?.login ?? "").toLowerCase() === viewer && normalizedBody(entry.body).includes(response.marker));
}

function livePublicationIdentity(item) {
  const actorValue = apiJson("{login:.login}", ["/user"]);
  const actor = String(actorValue.login ?? "").toLowerCase();
  if (!LOGIN_RE.test(actor)) throw new PollError("authentication", "GitHub authentication did not identify a valid publication actor.");
  const pull = apiJson("{author:.user.login,head:.head.sha,state:.state}", [`/repos/${item.repository}/pulls/${item.number}`]);
  const author = String(pull.author ?? "").toLowerCase();
  if (!LOGIN_RE.test(author) || String(pull.state ?? "").toLowerCase() !== "open") {
    throw new PollError("github-read", "GitHub did not return a valid live pull-request author at the publication boundary.");
  }
  return { actor, author, head: validateSha(pull.head, "publication-boundary head") };
}

function refuseSelfReviewPublication(item, identity) {
  const method = item.response.method;
  item.publication_guard = {
    schema: PUBLICATION_GUARD_SCHEMA,
    decision: "self-review-publication-refused",
    actor: identity.actor,
    author: identity.author,
    method,
    head: identity.head,
    refused_at: NOW(),
  };
  if (item.review_outcome === "findings") {
    stagePrivateFindings(item, "publication-guard");
  } else if (item.review_outcome === "clean") {
    item.authored = true;
    item.independent_review = false;
    item.outcome = "reviewed-clean";
    item.response = null;
    item.state = "terminal";
  } else {
    die("self-review publication has no valid private review outcome");
  }
  writeItem(item);
  if (item.state === "terminal") laneRelease(item.id);
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-publication-refusal") process.exit(99);
  process.stdout.write(`${JSON.stringify({
    item_id: item.id,
    publication: "self-review-publication-refused",
    head: item.head,
    owner_task: item.owning_task,
    private_route: item.private_route?.status ?? "clean",
  })}\n`);
  process.exit(6);
}

function postResponse(item) {
  const response = item.response;
  if (response.method === "comment-only-review") {
    const temp = join(ROOT, `.response.${item.id}.${process.pid}.txt`);
    atomicWrite(temp, response.body);
    const result = spawnSync("gh-axi", ["pr", "review", String(item.number), "--repo", item.repository, "--comment", "--body-file", temp], {
      encoding: "utf8",
      timeout: API_TIMEOUT_MS,
      maxBuffer: 262144,
      stdio: ["ignore", "pipe", "pipe"],
    });
    rmSync(temp, { force: true });
    if (result.error || result.status !== 0) throw new PollError("reply", "Comment-only review delivery failed and remains queued for retry.");
    return;
  }
  if (response.method === "fallback-comment") {
    throw new PollError("reply", "Replacement review comments are not a supported publication path.");
  }
  if (!item.feedback || !["inline-reply", "issue-comment"].includes(response.method)) {
    throw new PollError("reply", "Pending response method is not supported.");
  }
  const endpoint = response.method === "inline-reply"
    ? `/repos/${item.repository}/pulls/${item.number}/comments/${item.feedback.parent_thread_id}/replies`
    : `/repos/${item.repository}/issues/${item.number}/comments`;
  apiJson("{id,node_id,html_url}", ["POST", endpoint, "--field", `body=${response.body}`], true);
}

function deliver(args) {
  const flags = parseFlags(args);
  requireOnly(flags, []);
  const item = readItem(flags._[0]);
  if (item.state !== "response-pending" || !item.response || item.response.state !== "pending") die("item has no pending response", 4);
  deadline = Date.now() + POLL_BUDGET_MS;
  requireCoreHeadroom(MAX_PAGES + 8);
  const current = currentHead(item);
  if (current !== item.response.head || current !== item.head) {
    item.head = current;
    item.generation += 1;
    item.state = "pending";
    item.outcome = null;
    item.response = null;
    item.evidence = null;
    if (item.type === "initial-review") {
      item.review_outcome = null;
      item.independent_review = false;
      item.private_route = null;
      item.publication_guard = null;
    }
    delete item.validation;
    item.updated_at = NOW();
    writeItem(item);
    process.stdout.write(`${JSON.stringify({ requeued: item.id, head: current, generation: item.generation })}\n`);
    process.exit(5);
  }
  const snapshot = readSnapshot();
  const viewer = snapshot.viewer || String(process.env.FM_PR_REVIEW_VIEWER ?? "").toLowerCase();
  if (!LOGIN_RE.test(viewer)) die("authenticated reply identity is unavailable");
  let found = existingResponse(item, viewer);
  if (SELF_REVIEW_PUBLICATION_METHODS.has(item.response.method)) {
    const identity = livePublicationIdentity(item);
    if (identity.head !== item.response.head || identity.head !== item.head) {
      item.head = identity.head;
      item.generation += 1;
      item.state = "pending";
      item.outcome = null;
      item.response = null;
      item.evidence = null;
      item.review_outcome = null;
      item.independent_review = false;
      item.private_route = null;
      item.publication_guard = null;
      item.updated_at = NOW();
      writeItem(item);
      process.stdout.write(`${JSON.stringify({ requeued: item.id, head: identity.head, generation: item.generation })}\n`);
      process.exit(5);
    }
    if (identity.actor === identity.author) refuseSelfReviewPublication(item, identity);
  }
  if (!found) {
    try {
      postResponse(item);
      item.retry_count += 1;
      item.response.attempt_count += 1;
      writeItem(item);
      if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-post") process.exit(99);
      found = existingResponse(item, viewer);
      if (!found) die("GitHub accepted no verifiable response; the bound response remains queued for retry");
    } catch (error) {
      item.retry_count += 1;
      item.response.attempt_count += 1;
      writeItem(item);
      die(error instanceof PollError ? error.message : "GitHub response failed and remains queued for retry");
    }
  }
  item.response.state = "delivered";
  item.response.github_node = String(found.node_id ?? found.id ?? found.html_url ?? "verified");
  item.state = "terminal";
  item.updated_at = NOW();
  writeItem(item);
  if (process.env.FM_PR_REVIEW_TEST_CRASH_AT === "after-terminal") process.exit(99);
  laneRelease(item.id);
  process.stdout.write(`${JSON.stringify({ item_id: item.id, outcome: item.outcome, response: "delivered", github_node: item.response.github_node })}\n`);
}

function optOut(url) {
  ensureState();
  const parsed = parseUrl(url);
  const path = join(OPTOUTS, `${sha256(parsed.url).slice(0, 24)}.json`);
  atomicWrite(path, { schema: OPTOUT_SCHEMA, url: parsed.url, opted_out_at: NOW() });
  for (const item of allItems().filter((entry) => entry.url === parsed.url && !isTerminal(entry))) {
    item.prior_state = item.state;
    item.state = "opted-out";
    item.updated_at = NOW();
    writeItem(item);
    laneRelease(item.id);
  }
  process.stdout.write(`opted-out: ${parsed.url}\n`);
}

function optIn(url) {
  ensureState();
  const parsed = parseUrl(url);
  const path = join(OPTOUTS, `${sha256(parsed.url).slice(0, 24)}.json`);
  rmSync(path, { force: true });
  for (const item of allItems().filter((entry) => entry.url === parsed.url && entry.state === "opted-out")) {
    item.state = "pending";
    item.generation += 1;
    item.updated_at = NOW();
    delete item.prior_state;
    writeItem(item);
  }
  const control = readControl();
  control.next_poll = 0;
  writeControl(control);
  process.stdout.write(`coverage-restored: ${parsed.url}\n`);
}

function reopen(args) {
  const flags = parseFlags(args);
  requireOnly(flags, []);
  const item = readItem(flags._[0]);
  if (item.state !== "captain-decision-pending") die("item is not awaiting a captain decision", 4);
  item.state = "pending";
  item.outcome = null;
  item.generation += 1;
  item.updated_at = NOW();
  writeItem(item);
  process.stdout.write(`${JSON.stringify({ item_id: item.id, state: item.state, generation: item.generation })}\n`);
}

function listItems(json = false) {
  const rows = allItems();
  if (json) process.stdout.write(`${JSON.stringify(rows)}\n`);
  else for (const item of rows) process.stdout.write(`${item.id}\t${item.type}\t${item.state}\t${item.head}\t${item.url}\n`);
}

function nextItem() {
  const lane = laneRead();
  if (lane) {
    process.stdout.write(`${JSON.stringify({ lane: "occupied", item_id: lane.item_id, owner_task: lane.owner_task })}\n`);
    return;
  }
  const item = allItems().filter((entry) => entry.state === "pending").sort((a, b) => a.created_at - b.created_at || a.id.localeCompare(b.id))[0];
  if (!item) process.exit(3);
  process.stdout.write(`${JSON.stringify(item)}\n`);
}

function acknowledgeEvent(id) {
  if (!/^[0-9]{1,18}-[0-9a-f]{16}$/.test(String(id ?? ""))) die("event id is invalid", 2);
  const control = readControl();
  if (control.pending_event && control.pending_event.event_id !== id) die("event id does not match the pending notification", 4);
  control.pending_event = null;
  writeControl(control);
  process.stdout.write(`acknowledged: ${id}\n`);
}

function secondsUntilDue() {
  ensureState();
  const control = readControl();
  const seconds = control.pending_event ? 0 : Math.max(0, control.next_poll - NOW());
  process.stdout.write(`${seconds}\n`);
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case "init": ensureState(); break;
    case "poll": poll(); break;
    case "seconds-until-due": secondsUntilDue(); break;
    case "list": listItems(args.includes("--json")); break;
    case "show": process.stdout.write(`${JSON.stringify(readItem(args[0]), null, 2)}\n`); break;
    case "next": nextItem(); break;
    case "claim": claim(args); break;
    case "fetch-feedback": fetchFeedback(args); break;
    case "resolve-feedback": resolveFeedback(args); break;
    case "complete-review": completeReview(args); break;
    case "deliver": deliver(args); break;
    case "opt-out": optOut(args[0]); break;
    case "opt-in": optIn(args[0]); break;
    case "reopen": reopen(args); break;
    case "acknowledge-event": acknowledgeEvent(args[0]); break;
    default: die(`unknown state command: ${command ?? ""}`, 2);
  }
}

try {
  main();
} catch (error) {
  if (error instanceof PollError) die(error.message);
  throw error;
}
