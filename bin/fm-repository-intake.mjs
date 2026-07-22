#!/usr/bin/env node
// Daily repository intake for Firstmate's existing wake and backlog loop.
//
// Only allowlisted GitHub metadata is requested and retained. Issue/PR bodies,
// comments, credentials, and arbitrary command output never enter the checkpoint.
// docs/repository-intake.md owns the contract; this file owns mechanics.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const SCHEMA = "fm-repository-intake.v1";
const OUTCOME_SCHEMA = "fm-repository-intake-outcome.v1";
const TIME_ZONE = "Asia/Kolkata";
const CATEGORIES = [
  "newly_discovered",
  "verified_fixed",
  "closed_evidence",
  "grouped_design",
  "implementing",
  "pr_ready_or_merged",
  "blocked",
];
const EVIDENCE_REQUIRED = new Set(CATEGORIES.slice(1));
const RISK_KEYS = [
  "security_sensitive",
  "credential_sensitive",
  "live_data",
  "destructive",
  "deployment",
  "store",
  "trading",
  "external_communication",
  "financial",
];
const SECRET_VALUE = /(?:\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bsk-[A-Za-z0-9_-]{16,}\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b)/g;
const SENSITIVE_HINTS = {
  security_sensitive: /\b(?:security|vulnerability|cve|xss|csrf|injection|exploit)\b/i,
  credential_sensitive: /\b(?:credential|password|secret|token|api[ _-]?key|private[ _-]?key)\b/i,
  live_data: /\b(?:live[ _-]?data|production[ _-]?data|customer[ _-]?data)\b/i,
  destructive: /\b(?:destructive|delete|drop|purge|erase|wipe)\b/i,
  deployment: /\b(?:deploy|deployment|production|release)\b/i,
  store: /\b(?:app[ _-]?store|play[ _-]?store|publish)\b/i,
  trading: /\b(?:trading|trade|broker|order execution|position)\b/i,
  external_communication: /\b(?:email users|notify users|external communication|announcement)\b/i,
  financial: /\b(?:payment|billing|revenue|money|bank|financial)\b/i,
};

function fail(message, code = 2) {
  process.stderr.write(`fm-repository-intake: ${message}\n`);
  process.exit(code);
}

function parsePositiveInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^[1-9][0-9]*$/.test(raw)) fail(`${name} must be a positive integer`);
  return Number(raw);
}

function parseArgs(argv) {
  const args = {
    root: "",
    home: "",
    checkpoint: "",
    projects: "",
    now: process.env.FM_REPOSITORY_INTAKE_NOW || "",
    output: "human",
    mode: "refresh-if-due",
    outcome: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (["--root", "--home", "--checkpoint", "--projects", "--now", "--record-outcome"].includes(arg)) {
      if (i + 1 >= argv.length) fail(`${arg} requires a value`);
      const key = arg === "--record-outcome" ? "outcome" : arg.slice(2);
      args[key] = argv[i + 1];
      i += 1;
    } else if (arg === "--json") args.output = "json";
    else if (arg === "--attention-fingerprint") args.output = "fingerprint";
    else if (arg === "--refresh") args.mode = "refresh";
    else if (arg === "--show") args.mode = "show";
    else if (arg === "-h" || arg === "--help") {
      process.stdout.write(
        "usage: fm-repository-intake.sh [--json|--attention-fingerprint] [--refresh|--show]\n" +
        "       fm-repository-intake.sh --record-outcome <trusted-json-file> [--json]\n",
      );
      process.exit(0);
    } else fail(`unknown argument: ${arg}`);
  }
  if (!args.root || !args.home) fail("--root and --home are required");
  if (!args.projects) args.projects = path.join(args.home, "data", "projects.md");
  if (!args.checkpoint) args.checkpoint = path.join(args.home, "data", "repository-intake", "checkpoint.json");
  if (args.outcome) args.mode = "record-outcome";
  return args;
}

function sha(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function nowDate(value) {
  const date = value ? new Date(value) : new Date();
  if (!Number.isFinite(date.getTime())) fail("--now must be an ISO-8601 timestamp");
  return date;
}

function dayInKolkata(date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function sanitize(value, max = 240) {
  let text = String(value ?? "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  SECRET_VALUE.lastIndex = 0;
  text = text.replace(SECRET_VALUE, "[REDACTED]");
  text = text.replace(/\b(password|token|secret|api[ _-]?key)\s*[:=]\s*\S+/gi, "$1=[REDACTED]");
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function containsSecret(value) {
  if (typeof value === "string") {
    SECRET_VALUE.lastIndex = 0;
    return SECRET_VALUE.test(value);
  }
  if (Array.isArray(value)) return value.some(containsSecret);
  if (value && typeof value === "object") return Object.values(value).some(containsSecret);
  return false;
}

function readJson(file, required = false) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (!required && error?.code === "ENOENT") return null;
    throw new Error(`${path.basename(file)} is unreadable or invalid JSON`);
  }
}

function emptyState() {
  return {
    schema: SCHEMA,
    timezone: TIME_ZONE,
    last_attempt: null,
    last_success: null,
    projects: [],
    items: [],
  };
}

function readState(file) {
  const state = readJson(file);
  if (!state) return emptyState();
  if (state.schema !== SCHEMA || !Array.isArray(state.projects) || !Array.isArray(state.items)) {
    throw new Error("checkpoint has an unsupported or invalid schema");
  }
  return state;
}

function atomicWrite(file, value) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dir, 0o700);
  const temp = path.join(dir, `.checkpoint.${process.pid}.${crypto.randomBytes(5).toString("hex")}.tmp`);
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}

function acquireLock(checkpoint) {
  const lock = path.join(path.dirname(checkpoint), ".lock");
  fs.mkdirSync(path.dirname(lock), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(lock), 0o700);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      fs.mkdirSync(lock, { mode: 0o700 });
      fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: process.pid }), { mode: 0o600 });
      return { held: true, path: lock };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      let owner = null;
      try { owner = readJson(path.join(lock, "owner.json")); } catch { owner = null; }
      const pid = Number(owner?.pid);
      if (Number.isInteger(pid) && pid > 1) {
        try {
          process.kill(pid, 0);
          return { held: false, path: lock };
        } catch (probeError) {
          if (probeError?.code === "EPERM") return { held: false, path: lock };
        }
      } else {
        // Another process can be between the atomic mkdir and its tiny owner
        // write. Never evict that live-looking lock; only a lock with neither a
        // usable owner nor recent activity is recoverable after a crash.
        let ageMs = 0;
        try { ageMs = Date.now() - fs.statSync(lock).mtimeMs; } catch { ageMs = 0; }
        if (ageMs < 300_000) return { held: false, path: lock };
      }
      fs.rmSync(lock, { recursive: true });
    }
  }
  return { held: false, path: lock };
}

function releaseLock(lock) {
  if (lock?.held) fs.rmSync(lock.path, { recursive: true });
}

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd: options.cwd,
    encoding: "utf8",
    timeout: options.timeout || 30_000,
    maxBuffer: 16 * 1024 * 1024,
    env: process.env,
  });
  return { ok: result.status === 0, stdout: result.stdout || "", error: result.error };
}

function parseProjects(file, home) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return [{ id: "registry", status: "unavailable", error: "projects registry unavailable" }];
  }
  const projects = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^-\s+([^\s\[]+)(?:\s+\[([^\]]*)\])?\s+-/);
    if (!match) continue;
    const tokens = (match[2] || "").trim().split(/\s+/).filter(Boolean);
    const mode = tokens.find((token) => token !== "+yolo") || "no-mistakes";
    projects.push({
      id: match[1],
      path: path.join(home, "projects", match[1]),
      delivery_mode: ["no-mistakes", "direct-PR", "local-only"].includes(mode) ? mode : "no-mistakes",
      yolo: tokens.includes("+yolo"),
      status: "pending",
    });
  }
  return projects.length > 0 ? projects : [{ id: "registry", status: "unavailable", error: "projects registry has no project entries" }];
}

function githubIdentity(remote) {
  const clean = remote.trim();
  const patterns = [
    /^git@github\.com:([^/]+)\/([^/]+?)(?:\.git)?$/i,
    /^https?:\/\/github\.com\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/i,
    /^ssh:\/\/git@github\.com\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/i,
  ];
  for (const pattern of patterns) {
    const match = clean.match(pattern);
    if (match) return { host: "github.com", owner: match[1], name: match[2], key: `${match[1]}/${match[2]}`.toLowerCase() };
  }
  return null;
}

function resolveProject(project) {
  if (project.status === "unavailable") return project;
  const top = run("git", ["-C", project.path, "rev-parse", "--show-toplevel"]);
  const remote = top.ok ? run("git", ["-C", project.path, "remote", "get-url", "origin"]) : { ok: false };
  if (!top.ok || !remote.ok) return { ...project, status: "unavailable", error: "registered project clone or origin unavailable" };
  const identity = githubIdentity(remote.stdout);
  if (!identity) return { ...project, status: "unavailable", error: "registered project origin is not a supported GitHub remote" };
  return { ...project, status: "ready", repo: identity, path: fs.realpathSync(project.path) };
}

function scalar(raw) {
  const value = raw.trim();
  if (value === "null") return null;
  if (value === "true") return true;
  if (value === "false") return false;
  if (/^-?[0-9]+$/.test(value)) return Number(value);
  if (value.startsWith('"')) {
    try { return JSON.parse(value); } catch { return value.slice(1, -1); }
  }
  return value;
}

function parseGraphqlPage(text, kind) {
  if (/^\s*repository:\s+null\s*$/m.test(text)) throw new Error("repository unavailable through GitHub");
  const items = [];
  let current = null;
  let itemIndent = -1;
  let inLabels = false;
  let section = "";
  const pageInfo = { hasNextPage: false, endCursor: null };
  const rateLimit = { remaining: null, resetAt: null, cost: null };
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    const indent = line.length - line.trimStart().length;
    const numberMatch = trimmed.match(/^- number:\s*(\d+)$/);
    if (numberMatch) {
      if (current) items.push(current);
      current = { number: Number(numberMatch[1]), labels: [] };
      itemIndent = indent;
      inLabels = false;
      section = "items";
      continue;
    }
    if (trimmed === "pageInfo:") {
      if (current) { items.push(current); current = null; }
      section = "pageInfo";
      inLabels = false;
      continue;
    }
    if (trimmed === "rateLimit:") {
      if (current) { items.push(current); current = null; }
      section = "rateLimit";
      inLabels = false;
      continue;
    }
    if (current && indent === itemIndent + 2 && trimmed === "labels:") {
      inLabels = true;
      continue;
    }
    const labelMatch = inLabels && trimmed.match(/^- name:\s*(.*)$/);
    if (current && labelMatch) {
      current.labels.push(sanitize(scalar(labelMatch[1]), 80));
      continue;
    }
    const field = trimmed.match(/^([A-Za-z][A-Za-z0-9]*):\s*(.*)$/);
    if (!field) continue;
    const [, key, raw] = field;
    if (current && indent === itemIndent + 2 && key !== "labels") {
      inLabels = false;
      current[key] = scalar(raw);
    } else if (section === "pageInfo" && ["hasNextPage", "endCursor"].includes(key)) pageInfo[key] = scalar(raw);
    else if (section === "rateLimit" && ["remaining", "resetAt", "cost"].includes(key)) rateLimit[key] = scalar(raw);
  }
  if (current) items.push(current);
  for (const item of items) {
    for (const required of ["number", "title", "updatedAt", "url"]) {
      if (item[required] === undefined || item[required] === null) throw new Error(`GitHub ${kind} response omitted ${required}`);
    }
    if (kind === "pr" && !item.headRefOid) throw new Error("GitHub pull request response omitted headRefOid");
  }
  return { items, pageInfo, rateLimit };
}

const ISSUE_QUERY = "query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){issues(states:OPEN,first:100,after:$cursor,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title updatedAt url labels(first:20){nodes{name}}}pageInfo{hasNextPage endCursor}}}rateLimit{remaining resetAt cost}}";
const PR_QUERY = "query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,after:$cursor,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title updatedAt url isDraft headRefOid baseRefName labels(first:20){nodes{name}} reviewDecision}pageInfo{hasNextPage endCursor}}}rateLimit{remaining resetAt cost}}";

function fetchConnection(project, kind, settings) {
  const all = [];
  let cursor = null;
  let lastRate = { remaining: null, resetAt: null, cost: null };
  for (let page = 0; page < settings.maxPages; page += 1) {
    const query = kind === "issue" ? ISSUE_QUERY : PR_QUERY;
    const commandArgs = ["api", "POST", "graphql", "--field", `query=${query}`, "--field", `owner=${project.repo.owner}`, "--field", `name=${project.repo.name}`];
    if (cursor) commandArgs.push("--field", `cursor=${cursor}`);
    const result = run(settings.gh, commandArgs, { timeout: settings.timeout });
    if (!result.ok) throw new Error("GitHub API unavailable");
    const parsed = parseGraphqlPage(result.stdout, kind);
    all.push(...parsed.items);
    lastRate = parsed.rateLimit;
    if (!parsed.pageInfo.hasNextPage) return { items: all, rateLimit: lastRate };
    if (!parsed.pageInfo.endCursor) throw new Error("GitHub pagination cursor missing");
    if (Number.isInteger(lastRate.remaining) && lastRate.remaining <= settings.reserve) {
      const error = new Error("GitHub rate-limit reserve reached");
      error.rateLimit = lastRate;
      throw error;
    }
    cursor = String(parsed.pageInfo.endCursor);
  }
  throw new Error(`GitHub ${kind} pagination exceeded the configured bound`);
}

function sourceFingerprint(item) {
  const fields = item.type === "issue"
    ? [item.type, item.number, item.updated_at, item.title, item.labels]
    : [item.type, item.number, item.updated_at, item.title, item.labels, item.head_sha, item.base_branch, item.draft, item.review_decision];
  return sha(JSON.stringify(fields));
}

function normalizedItem(project, kind, raw, observedAt) {
  const item = {
    id: `github:${project.repo.key}:${kind}:${raw.number}`,
    project_id: project.id,
    repository: project.repo.key,
    type: kind,
    number: raw.number,
    url: sanitize(raw.url, 500),
    title: sanitize(raw.title),
    labels: [...new Set(raw.labels.map((label) => sanitize(label, 80)))].sort(),
    updated_at: String(raw.updatedAt),
    observed_at: observedAt,
    open: true,
  };
  if (kind === "pr") {
    item.draft = Boolean(raw.isDraft);
    item.head_sha = sanitize(raw.headRefOid, 80);
    item.base_branch = sanitize(raw.baseRefName, 120);
    item.review_decision = raw.reviewDecision === null ? null : sanitize(raw.reviewDecision, 80);
  }
  item.source_fingerprint = sourceFingerprint(item);
  return item;
}

function resetOutcome(previous, reason) {
  const history = Array.isArray(previous?.outcome_history) ? previous.outcome_history.slice(-4) : [];
  if (previous?.outcome && previous.outcome.status !== "newly_discovered") history.push(previous.outcome);
  return {
    outcome: { status: "newly_discovered", recorded_at: null, evidence: [] },
    outcome_history: history.slice(-5),
    attention_reason: reason,
  };
}

function reconcileItems(previousItems, observations, fullyObservedRepos, observedAt, retentionDays) {
  const previous = new Map(previousItems.map((item) => [item.id, item]));
  const current = new Map();
  for (const observed of observations) {
    const old = previous.get(observed.id);
    if (!old) {
      current.set(observed.id, {
        ...observed,
        first_seen_at: observedAt,
        last_seen_at: observedAt,
        ...resetOutcome(null, "new_open_work"),
      });
    } else if (old.source_fingerprint !== observed.source_fingerprint || old.open === false) {
      current.set(observed.id, {
        ...old,
        ...observed,
        first_seen_at: old.first_seen_at || observedAt,
        last_seen_at: observedAt,
        ...resetOutcome(old, old.open === false ? "reopened_work" : "source_changed"),
      });
    } else {
      current.set(observed.id, { ...old, ...observed, last_seen_at: observedAt });
    }
  }
  for (const old of previousItems) {
    if (current.has(old.id)) continue;
    if (!fullyObservedRepos.has(old.repository)) {
      current.set(old.id, old);
      continue;
    }
    if (old.open === false) {
      current.set(old.id, old);
      continue;
    }
    current.set(old.id, {
      ...old,
      open: false,
      observed_at: observedAt,
      last_seen_at: observedAt,
      ...resetOutcome(old, "no_longer_open_requires_verification"),
    });
  }
  const cutoff = Date.parse(observedAt) - retentionDays * 86_400_000;
  return [...current.values()]
    .filter((item) => {
      const complete = item.outcome?.status === "closed_evidence"
        || (item.outcome?.status === "pr_ready_or_merged" && item.outcome?.disposition === "merged");
      if (item.open || !complete) return true;
      const recorded = Date.parse(item.outcome?.recorded_at || "");
      return Number.isFinite(recorded) && recorded >= cutoff;
    })
    .sort((a, b) => a.id.localeCompare(b.id));
}

function retryDue(state, now) {
  if (state.last_attempt?.status !== "rate_limited" || !state.last_attempt.retry_after) return false;
  const retry = Date.parse(state.last_attempt.retry_after);
  return Number.isFinite(retry) && now.getTime() >= retry;
}

function refreshDue(state, day, now, mode) {
  if (mode === "refresh") return true;
  if (mode === "show") return false;
  return state.last_attempt?.day !== day || retryDue(state, now);
}

function refreshState(state, args, now) {
  const observedAt = now.toISOString();
  const day = dayInKolkata(now);
  const settings = {
    gh: process.env.FM_GH_AXI || "gh-axi",
    timeout: parsePositiveInt("FM_REPOSITORY_INTAKE_TIMEOUT", 30) * 1000,
    maxPages: parsePositiveInt("FM_REPOSITORY_INTAKE_MAX_PAGES", 100),
    reserve: parsePositiveInt("FM_REPOSITORY_INTAKE_RATE_LIMIT_RESERVE", 100),
    retentionDays: parsePositiveInt("FM_REPOSITORY_INTAKE_RETENTION_DAYS", 30),
  };
  const projects = parseProjects(args.projects, args.home).map(resolveProject);
  const observations = [];
  const fullyObservedRepos = new Set();
  let status = projects.some((project) => project.status === "unavailable") ? "failed" : "success";
  let errorCode = status === "failed" ? "SOURCE_UNAVAILABLE" : null;
  let retryAfter = null;
  let remaining = null;

  for (let index = 0; index < projects.length; index += 1) {
    const project = projects[index];
    if (project.status !== "ready") continue;
    try {
      const issues = fetchConnection(project, "issue", settings);
      remaining = issues.rateLimit.remaining;
      observations.push(...issues.items.map((item) => normalizedItem(project, "issue", item, observedAt)));
      if (Number.isInteger(remaining) && remaining <= settings.reserve) {
        const error = new Error("GitHub rate-limit reserve reached");
        error.rateLimit = issues.rateLimit;
        throw error;
      }
      const prs = fetchConnection(project, "pr", settings);
      remaining = prs.rateLimit.remaining;
      observations.push(...prs.items.map((item) => normalizedItem(project, "pr", item, observedAt)));
      fullyObservedRepos.add(project.repo.key);
      project.status = "observed";
      project.observed_at = observedAt;
      project.counts = { issues: issues.items.length, pull_requests: prs.items.length };
      project.source = { provider: "github-graphql", command: "gh-axi api POST graphql", retention: "allowlisted-metadata-only" };
      if (Number.isInteger(remaining) && remaining <= settings.reserve && index < projects.length - 1) {
        status = "rate_limited";
        errorCode = "RATE_LIMIT_RESERVE";
        retryAfter = prs.rateLimit.resetAt || null;
        break;
      }
    } catch (error) {
      const rate = error.rateLimit;
      project.status = rate ? "rate_limited" : "unavailable";
      project.error = rate ? "GitHub rate-limit reserve reached" : "GitHub API observation failed";
      status = rate ? "rate_limited" : "failed";
      errorCode = rate ? "RATE_LIMIT_RESERVE" : "API_UNAVAILABLE";
      retryAfter = rate?.resetAt || null;
      remaining = rate?.remaining ?? remaining;
      if (rate) break;
    }
  }
  for (const project of projects) {
    if (project.status === "ready") {
      project.status = "not_observed";
      project.error = status === "rate_limited" ? "deferred until authoritative rate-limit reset" : "daily intake stopped after source failure";
    }
  }
  const next = {
    schema: SCHEMA,
    timezone: TIME_ZONE,
    last_attempt: {
      day,
      observed_at: observedAt,
      status,
      error_code: errorCode,
      retry_after: retryAfter,
      rate_limit_remaining: remaining,
    },
    last_success: status === "success" ? { day, observed_at: observedAt } : state.last_success,
    projects: projects.map(({ path: projectPath, ...project }) => ({ ...project, source_path: projectPath || null })),
    items: reconcileItems(state.items, observations, fullyObservedRepos, observedAt, settings.retentionDays),
  };
  atomicWrite(args.checkpoint, next);
  return next;
}

function validateEvidence(evidence) {
  if (!Array.isArray(evidence) || evidence.length === 0 || evidence.length > 20) throw new Error("evidence must contain 1-20 records");
  return evidence.map((record) => {
    if (!record || typeof record !== "object" || Array.isArray(record)) throw new Error("each evidence record must be an object");
    const allowed = new Set(["source", "pointer", "observed_at", "claim"]);
    for (const key of Object.keys(record)) if (!allowed.has(key)) throw new Error(`unsupported evidence field: ${key}`);
    if (!record.source || !record.pointer || !record.observed_at || !record.claim) throw new Error("evidence requires source, pointer, observed_at, and claim");
    if (!Number.isFinite(Date.parse(record.observed_at))) throw new Error("evidence observed_at must be ISO-8601");
    return {
      source: sanitize(record.source, 80),
      pointer: sanitize(record.pointer, 500),
      observed_at: new Date(record.observed_at).toISOString(),
      claim: sanitize(record.claim, 240),
    };
  });
}

function validateOutcome(input, item, now) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("outcome record must be an object");
  if (containsSecret(input)) throw new Error("outcome record contains secret-like material");
  const allowed = new Set(["schema", "item_id", "source_fingerprint", "status", "evidence", "task_id", "group_id", "root_cause", "next_action", "blocker", "disposition", "checks_green", "risk"]);
  for (const key of Object.keys(input)) if (!allowed.has(key)) throw new Error(`unsupported outcome field: ${key}`);
  if (input.schema !== OUTCOME_SCHEMA) throw new Error(`outcome schema must be ${OUTCOME_SCHEMA}`);
  if (input.item_id !== item.id) throw new Error("outcome item_id does not match the selected item");
  if (input.source_fingerprint !== item.source_fingerprint) throw new Error("outcome source_fingerprint is stale");
  if (!CATEGORIES.includes(input.status)) throw new Error("unsupported outcome status");
  const evidence = EVIDENCE_REQUIRED.has(input.status) ? validateEvidence(input.evidence) : [];
  if (input.status === "grouped_design" && (!input.group_id || !input.root_cause)) throw new Error("grouped_design requires group_id and root_cause");
  if (input.status === "implementing" && (!input.task_id || !input.next_action)) throw new Error("implementing requires task_id and next_action");
  if (input.status === "blocked" && (!input.blocker || !input.next_action)) throw new Error("blocked requires blocker and next_action");
  if (input.status === "pr_ready_or_merged" && !["pr_ready", "merged"].includes(input.disposition)) throw new Error("pr_ready_or_merged requires disposition pr_ready or merged");
  if (input.status === "pr_ready_or_merged" && input.disposition === "pr_ready" && input.checks_green !== true) throw new Error("pr_ready requires checks_green=true");
  const risk = {};
  const givenRisk = input.risk || {};
  if (givenRisk && (typeof givenRisk !== "object" || Array.isArray(givenRisk))) throw new Error("risk must be an object");
  for (const key of Object.keys(givenRisk)) if (!RISK_KEYS.includes(key) || typeof givenRisk[key] !== "boolean") throw new Error(`unsupported risk field: ${key}`);
  const hints = `${item.title} ${item.labels.join(" ")}`;
  for (const key of RISK_KEYS) risk[key] = Boolean(givenRisk[key]) || SENSITIVE_HINTS[key].test(hints);
  return {
    status: input.status,
    recorded_at: now.toISOString(),
    evidence,
    task_id: input.task_id ? sanitize(input.task_id, 120) : null,
    group_id: input.group_id ? sanitize(input.group_id, 120) : null,
    root_cause: input.root_cause ? sanitize(input.root_cause) : null,
    next_action: input.next_action ? sanitize(input.next_action) : null,
    blocker: input.blocker ? sanitize(input.blocker) : null,
    disposition: input.disposition || null,
    checks_green: input.checks_green === true,
    risk,
  };
}

function recordOutcome(state, args, now) {
  const input = readJson(args.outcome, true);
  const item = state.items.find((candidate) => candidate.id === input.item_id);
  if (!item) throw new Error("outcome item_id is not present in the checkpoint");
  item.outcome = validateOutcome(input, item, now);
  item.attention_reason = null;
  atomicWrite(args.checkpoint, state);
  return state;
}

function projectFor(state, item) {
  return state.projects.find((project) => project.id === item.project_id) || {};
}

function riskSensitive(outcome) {
  return RISK_KEYS.some((key) => outcome?.risk?.[key] === true);
}

function attentionRecords(state) {
  const records = [];
  if (state.last_attempt?.status && state.last_attempt.status !== "success") {
    records.push({ id: `source:${state.last_attempt.day || "unknown"}`, reason: state.last_attempt.error_code || "SOURCE_UNKNOWN", severity: "critical" });
  }
  for (const project of state.projects) {
    if (!["observed"].includes(project.status)) records.push({ id: `project:${project.id}`, reason: project.error || project.status, severity: "critical" });
  }
  for (const item of state.items) {
    const outcome = item.outcome || { status: "newly_discovered" };
    const project = projectFor(state, item);
    let reason = item.attention_reason;
    let severity = "high";
    if (!reason && outcome.status === "verified_fixed") reason = "verified_fix_requires_issue_closure";
    if (!reason && outcome.status === "pr_ready_or_merged" && outcome.disposition === "pr_ready") reason = project.yolo && !riskSensitive(outcome) ? "routine_green_pr_can_land" : "authority_gate";
    if (!reason && outcome.status === "blocked") reason = "genuine_blocker";
    if (riskSensitive(outcome)) severity = "critical";
    if (reason) records.push({ id: item.id, reason, severity, status: outcome.status });
  }
  return records.sort((a, b) => `${a.id}:${a.reason}`.localeCompare(`${b.id}:${b.reason}`));
}

function derivedView(state, now) {
  const day = dayInKolkata(now);
  const categories = Object.fromEntries(CATEGORIES.map((category) => [category, []]));
  for (const item of state.items) {
    const project = projectFor(state, item);
    const outcome = item.outcome || { status: "newly_discovered" };
    const sensitive = riskSensitive(outcome);
    categories[outcome.status].push({
      id: item.id,
      project_id: item.project_id,
      type: item.type,
      number: item.number,
      title: item.title,
      url: item.url,
      open: item.open,
      updated_at: item.updated_at,
      source_fingerprint: item.source_fingerprint,
      attention_reason: item.attention_reason,
      task_id: outcome.task_id || null,
      group_id: outcome.group_id || null,
      disposition: outcome.disposition || null,
      authority: project.yolo && !sensitive ? "routine_autonomy" : "captain_required",
      sensitive,
      evidence: outcome.evidence || [],
    });
  }
  const attention = attentionRecords(state);
  const fingerprint = attention.length === 0 ? "none" : sha(JSON.stringify(attention));
  const highest = attention.some((item) => item.severity === "critical") ? "critical" : attention.length > 0 ? "high" : "none";
  const freshness = !state.last_success ? "unknown" : state.last_success.day === day ? "fresh" : "stale";
  return {
    schema: SCHEMA,
    generated_at: now.toISOString(),
    timezone: TIME_ZONE,
    calendar_day: day,
    checkpoint: {
      last_attempt: state.last_attempt,
      last_success: state.last_success,
      freshness,
    },
    source_scope: {
      registry: "data/projects.md",
      registered_projects: state.projects.length,
      observed_projects: state.projects.filter((project) => project.status === "observed").length,
      projects: state.projects,
    },
    categories,
    attention: { fingerprint, count: attention.length, highest_severity: highest, items: attention },
  };
}

function renderHuman(view) {
  const lines = [
    `Repository intake (${view.calendar_day} ${view.timezone})`,
    `Evidence: ${view.checkpoint.freshness}; last attempt ${view.checkpoint.last_attempt?.status || "never"}; projects ${view.source_scope.observed_projects}/${view.source_scope.registered_projects} observed`,
  ];
  const labels = {
    newly_discovered: "Newly discovered",
    verified_fixed: "Verified fixed",
    closed_evidence: "Closed with evidence",
    grouped_design: "Grouped for design",
    implementing: "Implementing",
    pr_ready_or_merged: "PR-ready or merged",
    blocked: "Blocked",
  };
  for (const category of CATEGORIES) {
    const items = view.categories[category];
    lines.push(`${labels[category]}: ${items.length}`);
    for (const item of items.slice(0, 20)) lines.push(`  - ${item.project_id} ${item.type} #${item.number}: ${item.title}`);
    if (items.length > 20) lines.push(`  - ... ${items.length - 20} more (use --json)`);
  }
  lines.push(`Supervisor attention: ${view.attention.count} (${view.attention.highest_severity})`);
  for (const item of view.attention.items.slice(0, 20)) lines.push(`  - ${item.id}: ${item.reason}`);
  return `${lines.join("\n")}\n`;
}

const args = parseArgs(process.argv.slice(2));
const now = nowDate(args.now);
let state;
try {
  state = readState(args.checkpoint);
  if (args.mode === "record-outcome" || refreshDue(state, dayInKolkata(now), now, args.mode)) {
    const lock = acquireLock(args.checkpoint);
    if (lock.held) {
      try {
        state = readState(args.checkpoint);
        if (args.mode === "record-outcome") state = recordOutcome(state, args, now);
        else if (refreshDue(state, dayInKolkata(now), now, args.mode)) state = refreshState(state, args, now);
      } finally {
        releaseLock(lock);
      }
    }
  }
} catch (error) {
  fail(error.message, containsSecret(error.message) ? 3 : 2);
}

const view = derivedView(state, now);
if (args.output === "fingerprint") process.stdout.write(`${view.attention.fingerprint}\t${view.attention.count}\t${view.attention.highest_severity}\n`);
else if (args.output === "json") process.stdout.write(`${JSON.stringify(view, null, 2)}\n`);
else process.stdout.write(renderHuman(view));
