#!/usr/bin/env node
// Render the Firstmate fleet cockpit from live state.
//
// The cockpit shows exactly three things, in Pedro's priority order:
//   1. DECISIONS he must take now.
//   2. OUR PRS IN REVIEW.
//   3. REVIEWING - colleague PR relationships recorded by the reviews domain.
// The default is a fixed-measure one-line list; --show and watch selection own
// full context so titles never compete with status prose during a scan.
//
// Sources stay read-only: fm-fleet-snapshot.sh (built on fm-crew-state.sh and
// fm-classify-lib.sh) owns meta/status/backlog classification for this home
// and for the reviews domain's home, fm-model-telemetry.sh owns its attempt
// sheet, and the gh CLI supplies forge state for our own recorded PRs on a
// deliberately slow cadence with its data age printed plainly.
//
// Outputs:
//   default            one-shot ANSI terminal cockpit on stdout
//   --watch            live terminal loop; local state refreshes fast,
//                      GitHub state refreshes slowly and shows its age
//   --output <path>    self-contained HTML page (never under data/, state/,
//                      or config/)

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { emitKeypressEvents } from "node:readline";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const fleetHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || repositoryRoot);
const dataDirectory = resolve(process.env.FM_DATA_OVERRIDE || resolve(fleetHome, "data"));
const stateDirectory = resolve(process.env.FM_STATE_OVERRIDE || resolve(fleetHome, "state"));
const configDirectory = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(fleetHome, "config"));
const telemetryPath = resolve(dataDirectory, "routing-outcomes.jsonl");
const secondmatesPath = resolve(dataDirectory, "secondmates.md");

const WATCH_LOCAL_SECONDS = Number.parseInt(process.env.FM_FLEET_WATCH_LOCAL_SECONDS || "5", 10);
const WATCH_GITHUB_SECONDS = Number.parseInt(process.env.FM_FLEET_WATCH_GITHUB_SECONDS || "120", 10);
const GITHUB_PR_LIMIT = 6;
const MARKERS = Object.freeze({
  yellow: { glyph: "◆", label: "needs Pedro", color: "yellow" },
  red: { glyph: "×", label: "stuck", color: "red" },
  blue: { glyph: "○", label: "waiting elsewhere", color: "blue" },
  green: { glyph: "●", label: "progressing", color: "green" },
  unknown: { glyph: "?", label: "unknown", color: "magenta" },
});
const MARKER_PRIORITY = Object.freeze({ yellow: 0, red: 1, blue: 2, green: 3, unknown: 4 });

function usage(stream = process.stdout) {
  stream.write(`usage: fm-fleet-dashboard.mjs [--width <columns>] [--all] [--show <row>] [--watch] [--output <path>]

Render the fleet cockpit: decisions ranked by importance, our PRs in
review with actionable status, and the reviews domain's PR relationships.
--width <columns>  terminal frame width request (minimum 40; output capped at 80)
--all              compatibility flag; the compact default already lists every item
--show <row|id>    print one row's full context by position number or stable row id
--watch            live redraw: local state every ${WATCH_LOCAL_SECONDS}s, GitHub state every
                   ${WATCH_GITHUB_SECONDS}s; type a row number and Enter to expand, b goes back
--output <path>    write the self-contained HTML page to <path> instead
The HTML output may never be written under data/, state/, or config/.
`);
}

function parseArguments(argumentsList) {
  let outputPath = null;
  let width = null;
  let showAll = false;
  let showRow = null;
  let watch = false;
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "-h" || argument === "--help") {
      usage();
      process.exit(0);
    }
    if (argument === "--all") {
      showAll = true;
      continue;
    }
    if (argument === "--watch") {
      watch = true;
      continue;
    }
    if (argument === "--show" && index + 1 < argumentsList.length) {
      const supplied = argumentsList[index + 1];
      showRow = /^\d+$/.test(supplied) ? Number.parseInt(supplied, 10) : supplied;
      if ((typeof showRow === "number" && showRow < 1) || showRow === "") {
        throw new Error("--show requires a positive row number or stable row id");
      }
      index += 1;
      continue;
    }
    if (argument === "--output" && index + 1 < argumentsList.length) {
      const supplied = argumentsList[index + 1];
      outputPath = isAbsolute(supplied) ? resolve(supplied) : resolve(process.cwd(), supplied);
      index += 1;
      continue;
    }
    if (argument === "--width" && index + 1 < argumentsList.length) {
      width = Number.parseInt(argumentsList[index + 1], 10);
      if (!Number.isInteger(width) || width < 40) {
        throw new Error("--width requires an integer of at least 40");
      }
      index += 1;
      continue;
    }
    usage(process.stderr);
    throw new Error(`unknown or incomplete argument: ${argument}`);
  }
  if (showRow !== null && outputPath !== null) {
    throw new Error("--show and --output cannot be combined");
  }
  if (watch && (showRow !== null || outputPath !== null)) {
    throw new Error("--watch cannot be combined with --show or --output");
  }
  return { outputPath, width, showAll, showRow, watch };
}

function pathIsWithin(candidate, parent) {
  const pathFromParent = relative(parent, candidate);
  return pathFromParent === "" || (!pathFromParent.startsWith("..") && !isAbsolute(pathFromParent));
}

function assertSafeOutput(outputPath) {
  const forbiddenDirectories = new Set([
    resolve(repositoryRoot, "data"),
    resolve(repositoryRoot, "state"),
    resolve(repositoryRoot, "config"),
    dataDirectory,
    stateDirectory,
    configDirectory,
  ]);
  for (const forbiddenDirectory of forbiddenDirectories) {
    if (pathIsWithin(outputPath, forbiddenDirectory)) {
      throw new Error(`refusing dashboard output under ${forbiddenDirectory}`);
    }
  }
}

function run(command, argumentsList, environment = process.env) {
  try {
    return execFileSync(command, argumentsList, {
      encoding: "utf8",
      env: environment,
      maxBuffer: 16 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60000,
    });
  } catch (error) {
    const diagnostic = error.stderr?.toString().trim() || error.message;
    throw new Error(`${command} failed: ${diagnostic}`);
  }
}

function parseMeta(path) {
  if (!path || !existsSync(path)) {
    return {};
  }
  const values = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const separator = line.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const key = line.slice(0, separator);
    if (!(key in values)) {
      values[key] = line.slice(separator + 1);
    }
  }
  return values;
}

// Backlog prose can carry a CLI pager's own truncation artifact; the cockpit
// renders state, never tool output, so the artifact is folded into an ellipsis.
function cleanProse(value) {
  return String(value ?? "")
    .replaceAll(/\s*\(truncated,[^)]*\)/g, "…")
    .replaceAll(/\s+/g, " ")
    .trim();
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return null;
  }
  const wholeSeconds = Math.floor(seconds);
  if (wholeSeconds < 60) {
    return `${wholeSeconds}s`;
  }
  const minutes = Math.floor(wholeSeconds / 60);
  if (minutes < 60) {
    return `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 24) {
    return remainingMinutes === 0 ? `${hours}h` : `${hours}h ${remainingMinutes}m`;
  }
  const days = Math.floor(hours / 24);
  const remainingHours = hours % 24;
  return remainingHours === 0 ? `${days}d` : `${days}d ${remainingHours}h`;
}

function age(seconds) {
  const duration = formatDuration(seconds);
  return duration === null
    ? { seconds: null, label: "age unknown" }
    : { seconds, label: `for ${duration}` };
}

function secondsSince(epochMilliseconds, observedMilliseconds) {
  if (!Number.isFinite(epochMilliseconds) || !Number.isFinite(observedMilliseconds)) {
    return null;
  }
  const seconds = Math.floor((observedMilliseconds - epochMilliseconds) / 1000);
  return seconds >= 0 ? seconds : null;
}

function mtimeMilliseconds(path) {
  if (!path || !existsSync(path)) {
    return null;
  }
  try {
    return statSync(path).mtimeMs;
  } catch {
    return null;
  }
}

function taskAge(task, telemetry, observedMilliseconds) {
  if (telemetry && telemetry.seconds !== null) {
    return age(telemetry.seconds);
  }
  const statusMtime = mtimeMilliseconds(task.paths?.status_log?.path);
  if (statusMtime !== null) {
    return age(secondsSince(statusMtime, observedMilliseconds));
  }
  return age(secondsSince(mtimeMilliseconds(task.paths?.meta?.path), observedMilliseconds));
}

function telemetryForTask(task, telemetryRows, observedMilliseconds) {
  const meta = parseMeta(task.paths?.meta?.path);
  const attemptId = meta.telemetry_attempt || null;
  if (!attemptId || telemetryRows === null) {
    return null;
  }
  const row = telemetryRows.find((candidate) => candidate.attemptId === attemptId);
  if (!row) {
    return null;
  }
  const tuple = [row.harness, row.model, row.effort].filter(Boolean).join("/") || null;
  if (Number.isFinite(row.wallSeconds)) {
    return { seconds: row.wallSeconds, tuple };
  }
  const seconds = secondsSince(Date.parse(row.startedAt || ""), observedMilliseconds);
  return { seconds, tuple };
}

// The registry line format is owned by bin/fm-secondmate-registry-lib.sh; this
// reads only the fields needed to locate the reviews domain's local home.
function findReviewsDomain() {
  if (!existsSync(secondmatesPath)) {
    return { available: false, reason: "no secondmates registered in this home" };
  }
  let text;
  try {
    text = readFileSync(secondmatesPath, "utf8");
  } catch (error) {
    return { available: false, reason: `secondmate registry unreadable: ${error.message}` };
  }
  for (const line of text.split(/\r?\n/)) {
    const local = line.match(/^-\s+(\S+)\s+-\s+.+\(home:\s*([^;)]*);\s*scope:\s*(.*?);\s*projects:/);
    const remote = line.match(/^-\s+(\S+)\s+-\s+.+\(host:\s*[^;)]*;.*scope:\s*(.*?);\s*projects:/);
    if (local && /review/i.test(local[3])) {
      return { available: true, id: local[1], home: local[2].trim() };
    }
    if (remote && /review/i.test(remote[2])) {
      return { available: false, reason: `reviews domain '${remote[1]}' lives on a remote host` };
    }
  }
  return { available: false, reason: "no registered secondmate with a review scope" };
}

function reviewPrNumber(record) {
  const url = record.pr_url ?? record.links?.find((link) => /\/pull\/\d+/.test(link)) ?? null;
  const urlMatch = url?.match(/\/pull\/(\d+)/);
  if (urlMatch) {
    return urlMatch[1];
  }
  for (const value of [record.id, record.title]) {
    const match = String(value ?? "").match(/(?:^|[^a-z])(?:review-)?pr[-# ]?(\d+)/i);
    if (match) {
      return match[1];
    }
  }
  return null;
}

function reviewHead(record) {
  for (const value of [record.id, record.title]) {
    // Require both a digit and a hex letter so ordinary words such as
    // "feedback" never masquerade as a recorded commit identity.
    const tokens = String(value ?? "").split(/[^0-9a-z]+/i);
    const head = tokens.find(
      (candidate) => /^[0-9a-f]{7,40}$/i.test(candidate) && /\d/.test(candidate) && /[a-f]/i.test(candidate),
    );
    if (head) {
      return head.toLowerCase();
    }
  }
  return null;
}

function recordActivityDate(record) {
  return record.reported ?? record.done ?? record.merged ?? record.completion?.date ?? record.since ?? null;
}

function githubPrUrlFromProjectRemote(home, project, number) {
  if (!project || !/^[0-9A-Za-z._-]+$/.test(project) || !/^\d+$/.test(number ?? "")) {
    return null;
  }
  const projectsRoot = resolve(home, "projects");
  const projectPath = resolve(projectsRoot, project);
  if (!pathIsWithin(projectPath, projectsRoot) || !existsSync(projectPath)) {
    return null;
  }
  let remote;
  try {
    remote = run("git", ["-C", projectPath, "remote", "get-url", "origin"]).trim();
  } catch {
    return null;
  }
  let slug = null;
  for (const prefix of ["https://github.com/", "git@github.com:", "ssh://git@github.com/"]) {
    if (remote.startsWith(prefix)) {
      slug = remote.slice(prefix.length).replace(/\.git$/, "");
      break;
    }
  }
  return slug && /^[^/\s]+\/[^/\s]+$/.test(slug) ? `https://github.com/${slug}/pull/${number}` : null;
}

function collectReviewRelationships() {
  const domain = findReviewsDomain();
  if (!domain.available) {
    return { available: false, reason: domain.reason, relationships: [] };
  }
  if (!existsSync(domain.home)) {
    return { available: false, reason: `reviews home is gone: ${domain.home}`, relationships: [] };
  }
  let snapshot;
  try {
    const text = run(resolve(scriptDirectory, "fm-fleet-snapshot.sh"), ["--json"], {
      ...process.env,
      FM_HOME: domain.home,
      FM_STATE_OVERRIDE: resolve(domain.home, "state"),
      FM_DATA_OVERRIDE: resolve(domain.home, "data"),
      FM_CONFIG_OVERRIDE: resolve(domain.home, "config"),
      FM_PROJECTS_OVERRIDE: resolve(domain.home, "projects"),
    });
    snapshot = JSON.parse(text);
  } catch (error) {
    return { available: false, reason: `reviews home unreadable: ${error.message}`, relationships: [] };
  }
  if (snapshot.backlog?.present !== true) {
    return { available: false, reason: "reviews home has no backlog", relationships: [] };
  }
  const groups = new Map();
  for (const record of snapshot.backlog.records || []) {
    if (!record.structured) {
      continue;
    }
    const number = reviewPrNumber(record);
    const key = number ? `pr:${number}` : `unknown:${record.id}`;
    if (!groups.has(key)) {
      groups.set(key, { number, records: [], heads: new Set(), links: new Set() });
    }
    const group = groups.get(key);
    group.records.push(record);
    const head = reviewHead(record);
    if (head) {
      group.heads.add(head);
    }
    for (const link of [record.pr_url, ...(record.links || [])].filter(Boolean)) {
      group.links.add(link);
    }
  }
  for (const record of snapshot.backlog.records || []) {
    for (const referencedId of record.blocked_by_ids || []) {
      const number = reviewPrNumber({ id: referencedId });
      const head = reviewHead({ id: referencedId });
      const group = number ? groups.get(`pr:${number}`) : null;
      if (group && head) {
        group.heads.add(head);
      }
    }
  }

  const relationships = [];
  for (const group of groups.values()) {
    const records = [...group.records].sort((left, right) => {
      const leftTime = Date.parse(recordActivityDate(left) || "") || 0;
      const rightTime = Date.parse(recordActivityDate(right) || "") || 0;
      return rightTime - leftTime || (left.order ?? 0) - (right.order ?? 0);
    });
    const current = records.find((record) => record.state !== "done") ?? records[0];
    const followupWithoutHistory = group.heads.size === 1 && records.some((record) =>
      /\bfinal\b|\bre-?review\b|\brecheck\b|\bverify\b/i.test(`${record.id} ${record.title}`),
    );
    const roundCount = group.heads.size > 0 && !followupWithoutHistory ? group.heads.size : null;
    const roundLabel = followupWithoutHistory
      ? "review round unknown (1 head recorded)"
      : roundCount === null
        ? "review count unknown"
        : `review x${roundCount}`;
    let status;
    if (!group.number) {
      status = `state ${current.state ?? "unknown"}; PR unknown`;
    } else if (current.state === "done") {
      status = `waiting on author after ${roundLabel}`;
    } else if (current.hold_reason) {
      status = `${cleanProse(current.hold_reason)} · ${roundLabel}`;
    } else if (current.unresolved_blocker_ids?.length) {
      status = `queued behind ${current.unresolved_blocker_ids.join(", ")} · ${roundLabel}`;
    } else if (current.state === "queued") {
      status = `${roundLabel} queued`;
    } else {
      status = `${roundLabel} · round under way`;
    }
    const recordedLink = [...group.links][0] ?? null;
    const derivedLink = recordedLink
      ? null
      : githubPrUrlFromProjectRemote(domain.home, current.repo, group.number);
    relationships.push({
      id: group.number ? `pr-${group.number}` : current.id,
      number: group.number,
      name: group.number ? `PR ${group.number}` : `PR unknown: ${cleanProse(current.title) || current.id}`,
      project: current.repo ?? null,
      link: recordedLink ?? derivedLink,
      linkSource: recordedLink ? "record" : derivedLink ? "verified_project_remote" : "absent",
      status,
      raw: records.map((record) => record.raw).filter(Boolean).join("\n"),
      since: recordActivityDate(records[0]),
      roundCount,
      workflowState: current.state ?? "unknown",
      holdReason: current.hold_reason ? cleanProse(current.hold_reason) : null,
    });
  }
  return { available: true, reason: null, home: domain.home, id: domain.id, relationships };
}

function githubStatus(data) {
  const checks = Array.isArray(data.statusCheckRollup) ? data.statusCheckRollup : [];
  const reviews = Array.isArray(data.reviews) ? data.reviews : null;
  const recordedReviews = new Set();
  for (const review of reviews ?? []) {
    const author = review.author?.login ?? null;
    if (author) {
      recordedReviews.add(`${author} (${String(review.state ?? "unknown").toLowerCase().replaceAll("_", " ")})`);
    }
  }
  const reviewerParts = [...recordedReviews];
  const changeRequesters = [...new Set((reviews ?? [])
    .filter((review) => review.state === "CHANGES_REQUESTED")
    .map((review) => review.author?.login)
    .filter(Boolean))];
  const requestedReviewers = Array.isArray(data.reviewRequests)
    ? [...new Set(data.reviewRequests
        .map((reviewer) => reviewer.login ?? reviewer.slug ?? reviewer.name)
        .filter(Boolean))]
    : [];
  const reviewSummary = reviews === null
    ? "reviewers unknown (not checked)"
    : reviewerParts.length === 0
      ? "no reviews reported"
      : `reviews recorded: ${reviewerParts.join(", ")}`;
  const conclusions = checks.map((check) => check.conclusion ?? check.state ?? null);
  const ciRed = conclusions.some((conclusion) =>
    ["ACTION_REQUIRED", "CANCELLED", "ERROR", "FAILURE", "STALE", "TIMED_OUT"].includes(conclusion),
  );
  const ciRunning = checks.some(
    (check) =>
      ["EXPECTED", "IN_PROGRESS", "PENDING", "QUEUED"].includes(check.state ?? check.status) ||
      (check.conclusion == null && check.state == null),
  );
  const knownGreen = conclusions.every((conclusion) => ["NEUTRAL", "SKIPPED", "SUCCESS"].includes(conclusion));
  const ci = checks.length === 0
    ? "CI none reported"
    : ciRed
      ? "CI red"
      : ciRunning
        ? "CI running"
        : knownGreen
          ? "CI green"
          : "CI unknown";

  let readiness;
  if (data.state === "MERGED") readiness = "merged";
  else if (data.state === "CLOSED") readiness = "closed";
  else if (data.isDraft === true) readiness = "draft - not ready for human review";
  else if (data.mergeable === "CONFLICTING") readiness = "resolving conflicts";
  else if (data.reviewDecision === "CHANGES_REQUESTED") readiness = "changes requested";
  else if (data.reviewDecision === "APPROVED" && ci === "CI green" && data.mergeable === "MERGEABLE") {
    readiness = "approved and ready to merge";
  } else if (data.reviewDecision === "APPROVED" && data.mergeable !== "MERGEABLE") {
    readiness = "approved; mergeability unknown";
  } else if (data.reviewDecision === "APPROVED") readiness = "approved; waiting on CI";
  else readiness = "waiting on human review";
  return {
    ci,
    readiness,
    forgeState: ["CLOSED", "MERGED", "OPEN"].includes(data.state)
      ? `${data.state.toLowerCase()}${data.isDraft === true ? " draft" : ""}`
      : "unknown",
    terminal: data.state === "MERGED" || data.state === "CLOSED",
    reviewSummary,
    changeRequesters,
    requestedReviewers,
  };
}

function isFirstmatePr(url) {
  return /^https:\/\/github\.com\/pedromuller-del\/firstmate\/pull\/\d+\/?$/i.test(url ?? "");
}

function checksLabel(ci) {
  const labels = {
    "CI green": "checks green",
    "CI red": "checks red",
    "CI running": "checks running",
    "CI none reported": "checks none reported",
    "CI unknown": "checks unknown",
    "CI unknown (not checked yet)": "checks unknown - not checked",
    "CI unknown (GitHub unavailable)": "checks unknown - GitHub unavailable",
  };
  return labels[ci] ?? "checks unknown";
}

function readinessLabel(githubResult) {
  if (!githubResult) return "readiness unknown - not checked";
  if (!githubResult.ok) {
    return githubResult.readiness.includes("GitHub unavailable")
      ? "readiness unknown - GitHub unavailable"
      : githubResult.readiness;
  }
  if (githubResult.readiness === "changes requested" && githubResult.changeRequesters.length > 0) {
    return `changes requested by ${githubResult.changeRequesters.join(", ")}`;
  }
  if (githubResult.readiness === "waiting on human review" && githubResult.requestedReviewers.length > 0) {
    return `waiting on ${githubResult.requestedReviewers.join(", ")}`;
  }
  return githubResult.readiness;
}

function firstmateReadiness(githubResult) {
  const label = readinessLabel(githubResult);
  return label.startsWith("approved") ? "approved; local checks unknown" : label;
}

function isStuckState(state) {
  return ["blocked", "dead", "failed", "missing", "unhealthy"].includes(state);
}

function isProgressState(state) {
  return ["active", "busy", "running", "working"].includes(state);
}

function ourPrMarker(state, registeredPr, githubResult) {
  if (isStuckState(state)) return { key: "red", source: "local" };
  if (isProgressState(state)) return { key: "green", source: "local" };
  if (!registeredPr) return { key: "unknown", source: "local" };
  if (!githubResult?.ok) return { key: "unknown", source: "forge" };
  if (githubResult.terminal) return { key: "green", source: "forge" };
  if (githubResult.readiness === "approved and ready to merge") return { key: "yellow", source: "forge" };
  if (githubResult.ci === "CI running" || githubResult.readiness === "waiting on human review") {
    return { key: "blue", source: "forge" };
  }
  return { key: "unknown", source: "forge" };
}

function ourPrRecommendation({ markerKey, registeredPr, githubResult, prNumber, firstmatePr }) {
  if (!registeredPr) {
    if (firstmatePr) {
      return `Register PR ${prNumber ?? "unknown"} for review status and record the exact local suite evidence.`;
    }
    return `Register PR ${prNumber ?? "unknown"} so its CI and review readiness can be established.`;
  }
  if (!githubResult?.ok) {
    return "GitHub state is unavailable; a successful status check is required before recommending an action.";
  }
  if (markerKey === "green") return "No action for Pedro; the task is progressing or finished cleanly.";
  if (githubResult.readiness === "approved and ready to merge") return "Approve the guarded merge when ready.";
  if (githubResult.readiness === "resolving conflicts") {
    return "Current task activity is unknown; establish whether conflict resolution resumed before intervening.";
  }
  if (githubResult.readiness === "changes requested") {
    return "Current task activity is unknown; establish whether work resumed before acting on requested changes.";
  }
  if (githubResult.ci === "CI red") {
    return "Current task activity is unknown; establish whether CI repair resumed before intervening.";
  }
  if (githubResult.ci === "CI running") return "Wait for CI; no action is supported unless it fails.";
  if (githubResult.readiness === "waiting on human review") {
    return "Wait for the reviewer; chase the review only if it stalls.";
  }
  return "The recorded PR facts do not establish a safe next action; another status check is required.";
}

// GitHub state is fetched on its own slow cadence because it is expensive and
// rate-limited, and its age is always printed so a cached CI result is never
// read as live.
function fetchGithubStatuses(urls) {
  const results = new Map();
  let error = null;
  for (const url of urls.slice(0, GITHUB_PR_LIMIT)) {
    if (!/^https:\/\/github\.com\//.test(url)) {
      results.set(url, {
        ok: false,
        ci: "CI unknown (not a github.com PR)",
        readiness: "review readiness unknown (not a github.com PR)",
      });
      continue;
    }
    try {
      const text = run("gh", [
        "pr",
        "view",
        url,
        "--json",
        "state,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,reviewRequests",
      ]);
      results.set(url, { ok: true, ...githubStatus(JSON.parse(text)) });
    } catch (fetchError) {
      results.set(url, {
        ok: false,
        ci: "CI unknown (GitHub unavailable)",
        readiness: "review readiness unknown (GitHub unavailable)",
      });
      error = fetchError.message.split("\n")[0];
    }
  }
  return { fetchedAtMs: Date.now(), results, error };
}

function buildModel({ snapshot, telemetryRows, telemetryPresent, reviews, github }) {
  const observedMilliseconds = Date.parse(snapshot.generated || "");
  const backlogPresent = snapshot.backlog?.present === true;
  const records = Array.isArray(snapshot.backlog?.records) ? snapshot.backlog.records : [];
  const tasks = Array.isArray(snapshot.tasks) ? snapshot.tasks : [];

  const sinceAge = (since) => age(secondsSince(Date.parse(since || ""), observedMilliseconds));
  const titleById = new Map(
    records
      .filter((record) => record.structured && record.id && record.title)
      .map((record) => [record.id, cleanProse(record.title)]),
  );
  const completedIds = new Set(
    records.filter((record) => record.structured && record.id && record.state === "done").map((record) => record.id),
  );
  const currentRecordsById = new Map(
    records
      .filter((record) => record.structured && record.id && record.state !== "done")
      .map((record) => [record.id, record]),
  );
  const blockingDeliveryIds = new Set(records.flatMap((record) => record.unresolved_blocker_ids || []));

  const decisions = [];
  const ours = [];
  const reviewing = [];

  for (const record of records) {
    if (!record.structured || record.state === "done") {
      continue;
    }
    if (record.hold_kind === "captain" && record.hold_reason && !record.unresolved_blocker_ids?.length) {
      const holdAge = sinceAge(record.since);
      const looksAnswered = /^(?:CAPTAIN\s+)?(?:DECIDED|ANSWERED)\b/.test(record.hold_reason);
      const aged = holdAge.seconds !== null && holdAge.seconds >= AGE_HOT_SECONDS;
      decisions.push({
        tag: looksAnswered ? "ANSWER?" : aged ? "AGED" : "HOLD",
        name: cleanProse(record.title) || record.id,
        id: record.id,
        project: record.repo ?? null,
        prose: looksAnswered
          ? `looks answered; hold still open: ${cleanProse(record.hold_reason)}`
          : aged
            ? `aged hold; still open: ${cleanProse(record.hold_reason)}`
            : cleanProse(record.hold_reason),
        note: null,
        age: holdAge,
        live: false,
        raw: record.raw,
        attentionClass: looksAnswered ? "answered" : aged ? "aged" : "now",
        stableKey: null,
        markerKey: looksAnswered ? "unknown" : "yellow",
        markerSource: "local",
        currentState: "captain hold open",
        blocker: cleanProse(record.hold_reason),
        recommendation: looksAnswered
          ? "Confirm the recorded answer so decision-hold-lifecycle can reconcile the still-open hold."
          : aged
            ? "Re-evaluate this aged captain hold and answer it or explicitly keep it open."
            : "Answer the recorded captain hold.",
        why: looksAnswered
          ? "the open hold's own text carries an explicit answer marker; decision lifecycle still owns closure"
          : aged
            ? "captain hold remains open but is at least seven days old; decision lifecycle still owns closure"
            : "captain hold with no unresolved blockers - only Pedro can clear it",
      });
    }
  }

  for (const task of tasks) {
    const telemetry = telemetryForTask(task, telemetryRows, observedMilliseconds);
    const itemAge = taskAge(task, telemetry, observedMilliseconds);
    const state = task.current_state?.state || "unknown";
    const detail = cleanProse(task.current_state?.detail);
    const currentRecord = currentRecordsById.get(task.id);
    const base = {
      name: titleById.get(task.id) || task.id,
      id: task.id,
      project: currentRecord?.repo || task.project || null,
      age: itemAge,
      live: task.endpoint?.exists === true,
      statusLog: task.paths?.status_log?.present ? task.paths.status_log.path : null,
      pr: task.pr?.url ? task.pr : null,
      report: task.paths?.report?.present ? task.paths.report.path : null,
      worktree: task.paths?.worktree?.path ?? null,
      currentState: state,
    };
    const openDecisions = task.hints?.open_decisions || [];
    for (const decision of openDecisions.filter((entry) => entry.verb === "needs-decision")) {
      decisions.push({
        ...base,
        tag: "DECIDE",
        prose: cleanProse(decision.summary) || "decision summary absent",
        note: decision.key && decision.key !== "default" ? `[${decision.key}]` : null,
        attentionClass: "now",
        stableKey: decision.key ?? "default",
        markerKey: "yellow",
        markerSource: "local",
        blocker: cleanProse(decision.summary) || "decision summary absent",
        recommendation: `Answer the recorded decision: ${cleanProse(decision.summary) || "the decision summary is missing"}`,
        why: "open needs-decision in the keyed decision fold, not yet resolved",
      });
    }
    for (const blocker of openDecisions.filter((entry) => entry.verb === "blocked")) {
      decisions.push({
        ...base,
        tag: "BLOCKED",
        prose: cleanProse(blocker.summary) || "blocker summary absent",
        note: blocker.key && blocker.key !== "default" ? `[${blocker.key}]` : null,
        attentionClass: "now",
        stableKey: blocker.key ?? "default",
        markerKey: "red",
        markerSource: "local",
        blocker: cleanProse(blocker.summary) || "blocker summary absent",
        recommendation: `Resolve the recorded blocker: ${cleanProse(blocker.summary) || "the blocker summary is missing"}`,
        why: "open blocked event in the keyed decision fold, not yet resolved",
      });
    }
    if (openDecisions.length === 0 && state === "blocked") {
      decisions.push({
        ...base,
        tag: "BLOCKED",
        prose: detail || "blocked, no detail reported",
        note: null,
        attentionClass: "now",
        stableKey: "blocked",
        markerKey: "red",
        markerSource: "local",
        blocker: detail || "blocked, no detail reported",
        recommendation: detail
          ? `Resolve the recorded blocker: ${detail}`
          : "The task is blocked but its blocker is missing; record the blocker before choosing an action.",
        why: "reconciled current state is blocked",
      });
    }

    // A current ship backlog title naming "PR N" plus task metadata is PR-stage
    // evidence even when pr= was never registered. Backlog prose alone and
    // status-event URLs are historical context, not evidence of a live PR row.
    const stageMatch = currentRecord?.kind === "ship"
      ? cleanProse(currentRecord.title).match(/\bPR\s*#?(\d+)\b/i)
      : null;
    const registeredPr = task.pr?.url && task.pr?.source === "meta";
    if (task.kind !== "secondmate" && !completedIds.has(task.id) && (registeredPr || stageMatch)) {
      const lastEvent = cleanProse(task.hints?.last_event_text).replaceAll(/https?:\/\/\S+/g, "").trim();
      const recorded = detail || lastEvent || "no status recorded";
      const githubResult = registeredPr ? github?.results?.get(task.pr.url) ?? null : null;
      const prNumber = stageMatch?.[1] ?? task.pr.url.match(/\/pull\/(\d+)/)?.[1] ?? null;
      const firstmatePr = base.project === "firstmate" || (registeredPr && isFirstmatePr(task.pr.url));
      const effectiveGithubResult = firstmatePr && githubResult
        ? {
            ...githubResult,
            ci: "CI unknown",
            readiness: firstmateReadiness(githubResult),
          }
        : githubResult;
      const checkStatus = firstmatePr
          ? "local checks unknown"
        : !registeredPr
          ? "checks unknown (unregistered)"
          : checksLabel(githubResult?.ci ?? "CI unknown (not checked yet)");
      const reviewStatus = !registeredPr
        ? "readiness unknown (unregistered)"
        : firstmatePr
          ? firstmateReadiness(githubResult)
          : readinessLabel(githubResult);
      const status = `${checkStatus} · ${reviewStatus}`;
      const marker = ourPrMarker(state, registeredPr, effectiveGithubResult);
      ours.push({
        ...base,
        tag: "OURS",
        prNumber,
        listLabel: `PR ${prNumber ?? "unknown"} | ${checkStatus} | ${reviewStatus}`,
        prose: status,
        note: registeredPr ? task.pr.url : null,
        markerKey: marker.key,
        markerSource: marker.source,
        blocker: status,
        review: registeredPr
          ? githubResult?.reviewSummary ?? "reviewers unknown (not checked yet)"
          : "reviewers unknown (PR not registered)",
        recommendation: ourPrRecommendation({
          markerKey: marker.key,
          registeredPr,
          githubResult: effectiveGithubResult,
          prNumber,
          firstmatePr,
        }),
        why: registeredPr
          ? "our PR recorded in task metadata and not yet landed in the backlog"
          : `current ship backlog record names PR ${prNumber ?? "unknown"}, but task metadata never registered it; last recorded: ${recorded}`,
      });
    }
  }

  for (const relationship of reviews.relationships) {
    const githubResult = relationship.link ? github?.results?.get(relationship.link) ?? null : null;
    if (githubResult?.terminal) {
      continue;
    }
    const forgeState = relationship.link
      ? githubResult
        ? githubResult.ok
          ? `forge ${githubResult.forgeState}`
          : githubResult.readiness
        : "forge state unknown (not checked yet)"
      : "forge state unknown (PR link not recorded)";
    const marker = !relationship.link || !githubResult?.ok
      ? { key: "unknown", source: "forge" }
      : relationship.holdReason || relationship.workflowState === "done"
        ? { key: "blue", source: "forge" }
        : relationship.workflowState === "in_flight"
          ? { key: "green", source: "forge" }
          : { key: "unknown", source: "forge" };
    const recommendation = marker.key === "blue"
      ? "Wait for the author or external party; chase them only if the review stalls."
      : marker.key === "green"
        ? "No action for Pedro; the review round is progressing."
        : "Forge or workflow state is missing; a fresh status check must establish whether action is needed.";
    reviewing.push({
      tag: "THEIRS",
      name: relationship.name,
      listLabel: `${relationship.number ? relationship.name : "PR unknown"} | ${relationship.status.replaceAll(" · ", " | ")}`,
      id: relationship.id,
      project: relationship.project,
      prose: `${relationship.status} · ${forgeState}`,
      note: relationship.link ?? "PR link unknown - not recorded in the review relationship",
      age: sinceAge(relationship.since),
      live: false,
      raw: relationship.raw,
      currentState: relationship.workflowState,
      pr: relationship.link ? { url: relationship.link, source: relationship.linkSource } : null,
      markerKey: marker.key,
      markerSource: marker.source,
      blocker: relationship.holdReason ?? relationship.status,
      review: relationship.status,
      recommendation,
      why: relationship.linkSource === "verified_project_remote"
        ? "review records grouped by PR; link established from the recorded PR number and verified project GitHub remote"
        : "review records grouped by PR; completed rounds remain until terminal PR evidence exists",
    });
  }

  // The printed ranking rule: a decision a person is waiting on right now
  // outranks one blocking queued delivery, which outranks pure age.
  const importanceTier = (item) => {
    if (item.attentionClass === "answered") return 3;
    if (item.attentionClass === "aged") return 4;
    if ((item.tag === "DECIDE" || item.tag === "BLOCKED") && item.live) return 0;
    if (blockingDeliveryIds.has(item.id)) return 1;
    return 2;
  };
  const oldestFirst = (left, right) => (right.age.seconds ?? -1) - (left.age.seconds ?? -1);
  decisions.sort((left, right) => importanceTier(left) - importanceTier(right) || oldestFirst(left, right));
  ours.sort(oldestFirst);
  reviewing.sort((left, right) => (left.age.seconds ?? Number.POSITIVE_INFINITY) - (right.age.seconds ?? Number.POSITIVE_INFINITY));

  for (const items of [decisions, ours, reviewing]) {
    items.sort((left, right) => MARKER_PRIORITY[left.markerKey] - MARKER_PRIORITY[right.markerKey]);
    for (const item of items) {
      item.marker = MARKERS[item.markerKey] ?? MARKERS.unknown;
    }
  }

  const localAttention = new Map();
  for (const item of [...decisions, ...ours, ...reviewing]) {
    if (item.markerSource === "local" && ["yellow", "red"].includes(item.markerKey)) {
      const identity = `${item.project ?? ""}/${item.id ?? item.name}`;
      if (!localAttention.has(identity)) localAttention.set(identity, item);
    }
  }

  const model = {
    generated: snapshot.generated || "observation time absent",
    backlogPresent,
    telemetryPresent,
    reviews,
    github,
    recap: {
      available: backlogPresent,
      needsPedro: [...localAttention.values()].filter((item) => item.markerKey === "yellow"),
      stuck: [...localAttention.values()].filter((item) => item.markerKey === "red"),
    },
    buckets: [
      {
        key: "decisions",
        name: "DECISIONS",
        htmlTitle: "Decisions",
        items: decisions,
        empty: backlogPresent ? "nothing needs a decision" : "backlog absent - captain holds unknown",
      },
      {
        key: "ours-in-review",
        name: "OUR PRS IN REVIEW",
        htmlTitle: "Our PRs in review",
        items: ours,
        empty: "no PR of ours recorded in review",
      },
      {
        key: "reviewing",
        name: "REVIEWING",
        htmlTitle: "Reviewing",
        items: reviewing,
        empty: reviews.available ? "no review relationships recorded" : `unavailable - ${reviews.reason}`,
      },
    ],
  };

  let rowNumber = 0;
  const rowEntries = [];
  for (const bucket of model.buckets) {
    for (const item of bucket.items) {
      rowNumber += 1;
      item.number = rowNumber;
      item.bucketName = bucket.name;
      const stablePart = bucket.key === "decisions"
        ? item.stableKey && item.stableKey !== item.id ? item.stableKey : item.id
        : bucket.key === "ours-in-review"
          ? item.prNumber ?? item.id
          : String(item.id).replace(/^pr-/, "");
      const prefix = bucket.key === "decisions" ? "d" : bucket.key === "ours-in-review" ? "o" : "r";
      const canonical = `${bucket.key}/${item.id}/${item.stableKey ?? ""}`;
      const natural = `${prefix}:${stablePart}`;
      const candidate = natural.length <= 20
        ? natural
        : `${prefix}:${createHash("sha256").update(canonical).digest("hex").slice(0, 8)}`;
      rowEntries.push({ item, canonical, candidate });
    }
  }
  const candidates = new Map();
  for (const entry of rowEntries) {
    const group = candidates.get(entry.candidate) ?? [];
    group.push(entry);
    candidates.set(entry.candidate, group);
  }
  for (const group of candidates.values()) {
    group.sort((left, right) => left.canonical.localeCompare(right.canonical));
    for (let index = 0; index < group.length; index += 1) {
      group[index].item.identity = group.length === 1
        ? group[index].candidate
        : `${group[index].candidate}-${index + 1}`;
    }
  }
  model.totalRows = rowNumber;
  return model;
}

const ANSI = {
  reset: "\u001b[0m",
  dim: "\u001b[2m",
  bold: "\u001b[1m",
  yellow: "\u001b[33m",
  red: "\u001b[31m",
  blue: "\u001b[34m",
  green: "\u001b[32m",
  magenta: "\u001b[35m",
};
const AGE_HOT_SECONDS = 7 * 86400;

function clip(text, width) {
  return text.length <= width ? text : `${text.slice(0, Math.max(0, width - 1))}…`;
}

function githubAgeLine(github, nowMs) {
  if (!github) {
    return "github status not checked";
  }
  const ageSeconds = secondsSince(github.fetchedAtMs, nowMs);
  const ageLabel = ageSeconds !== null && ageSeconds < 3 ? "just now" : `${formatDuration(ageSeconds) ?? "?"} ago`;
  if (github.error) {
    return `github unavailable (${github.error}) - last tried ${ageLabel}`;
  }
  return `github status checked ${ageLabel}`;
}

function recapFeaturedItems(recap) {
  const featured = [];
  if (recap.needsPedro[0]) featured.push(recap.needsPedro[0]);
  if (recap.stuck[0]) featured.push(recap.stuck[0]);
  for (const item of [...recap.needsPedro, ...recap.stuck]) {
    if (featured.length >= 2) break;
    if (!featured.includes(item)) featured.push(item);
  }
  return featured;
}

function recapNeedsPedroLabel(recap) {
  const aged = recap.needsPedro.filter((item) => item.attentionClass === "aged").length;
  const current = recap.needsPedro.length - aged;
  return `${recap.needsPedro.length} need Pedro - ${current} now, ${aged} aged over 7d`;
}

function renderTerminal(model, width, useColor, _showAll, nowMs = Date.now()) {
  width = Math.min(width, 80);
  const paint = (name, text) => (useColor && name ? `${ANSI[name]}${text}${ANSI.reset}` : text);
  const lines = [];
  lines.push(paint("bold", "FIRSTMATE FLEET"));
  lines.push(
    paint(
      "dim",
      clip(
        `observed ${model.generated} | ${githubAgeLine(model.github, nowMs)} | backlog ${model.backlogPresent ? "present" : "absent"}`,
        width,
      ),
    ),
  );
  lines.push(
    paint(
      "dim",
      clip(
        `sources backlog ${model.backlogPresent ? "present" : "absent"} | telemetry ${model.telemetryPresent ? "present" : "absent"} | token spend not measured`,
        width,
      ),
    ),
  );
  lines.push("");
  if (!model.recap.available) {
    lines.push(paint("bold", "ATTENTION NOW"));
    lines.push(paint("dim", "  unknown - backlog source absent"));
  } else if (model.recap.needsPedro.length === 0 && model.recap.stuck.length === 0) {
    lines.push(`${paint("bold", "ATTENTION NOW")} | nothing needs Pedro`);
  } else {
    lines.push(paint("bold", "ATTENTION NOW"));
    const counts = [
      model.recap.needsPedro.length > 0 ? recapNeedsPedroLabel(model.recap) : null,
      model.recap.stuck.length > 0 ? `${model.recap.stuck.length} stuck` : null,
    ].filter(Boolean);
    lines.push(`  ${counts.join(" | ")}`);
    const featured = recapFeaturedItems(model.recap);
    for (const item of featured) {
      lines.push(`  ${paint(item.marker.color, item.marker.glyph)} ${clip(item.name, Math.max(1, width - 4))}`);
    }
    const hidden = model.recap.needsPedro.length + model.recap.stuck.length - featured.length;
    if (hidden > 0) {
      lines.push(paint("dim", `  +${hidden} more below`));
    }
  }

  for (const bucket of model.buckets) {
    lines.push("");
    const label = `${bucket.name} (${bucket.items.length}) `;
    const header = `── ${label}${"─".repeat(Math.max(0, width - label.length - 3))}`;
    lines.push(paint("dim", clip(header, width)));
    if (bucket.items.length === 0) {
      lines.push(paint("dim", clip(`   ${bucket.empty}`, width)));
      continue;
    }
    const numberWidth = String(model.totalRows).length;
    for (const item of bucket.items) {
      const rowLabel = String(item.number).padStart(numberWidth);
      const prefix = `  ${rowLabel} `;
      const marker = paint(item.marker.color, item.marker.glyph);
      const stablePrefix = `${item.identity} `;
      const title = clip(item.listLabel ?? item.name, Math.max(1, width - prefix.length - stablePrefix.length - 2));
      lines.push(
        `${paint("dim", `${prefix}${stablePrefix}`)}${marker} ${paint(item.attentionClass === "aged" ? "dim" : null, title)}`,
      );
    }
  }
  lines.push("");
  lines.push(paint("dim", clip("◆ needs Pedro | × stuck | ○ waiting elsewhere | ● progressing | ? unknown", width)));
  return `${lines.join("\n")}\n`;
}

// Full single-item context: nothing truncated, every field sourced from data
// the cockpit already read.
function renderExpandedItem(item) {
  const lines = [];
  lines.push(`#${item.number} | ${item.bucketName} | ${item.marker.glyph} ${item.marker.label}`);
  lines.push(item.name || "(unnamed)");
  lines.push("");
  lines.push(`row id: ${item.identity}`);
  lines.push(`current state: ${item.currentState || "unknown"}`);
  lines.push(`age: ${item.age.label}`);
  if (item.prose) {
    lines.push(`detail: ${item.prose}`);
  }
  if (item.note) {
    lines.push(`note: ${item.note}`);
  }
  if (item.review) {
    lines.push(`review: ${item.review}`);
  }
  lines.push(`blocker/status: ${item.blocker || "none established"}`);
  lines.push(`recommendation: ${item.recommendation || "Evidence is incomplete; record current state before choosing an action."}`);
  lines.push(`why here: ${item.why || "routing reason not recorded"}`);
  const identity = [item.id ? `task ${item.id}` : null, item.project ? `project ${item.project}` : null]
    .filter(Boolean)
    .join(" · ");
  if (identity) {
    lines.push(identity);
  }
  lines.push(`pr: ${item.pr?.url ? `${item.pr.url} (source: ${item.pr.source})` : "none recorded"}`);
  lines.push(`report: ${item.report || "none"}`);
  if (item.worktree) {
    lines.push(`worktree: ${item.worktree}`);
  }
  if (item.raw) {
    lines.push(`backlog record: ${item.raw}`);
  }
  if (item.statusLog && existsSync(item.statusLog)) {
    const events = readFileSync(item.statusLog, "utf8")
      .split(/\r?\n/)
      .filter((line) => line.trim() !== "")
      .slice(-5);
    lines.push(`recent events (${item.statusLog}):`);
    for (const event of events) {
      lines.push(`  ${event}`);
    }
  } else if (item.id && !item.raw) {
    lines.push("recent events: no status log");
  }
  return `${lines.join("\n")}\n`;
}

// Every interactive and non-interactive expansion enters here so the later
// newness slice has one place to record a viewed row without touching renderers.
function expandRow(model, selection) {
  const items = model.buckets.flatMap((bucket) => bucket.items);
  const item = selection.identity
    ? items.find((candidate) => candidate.identity === selection.identity)
    : items.find((candidate) => candidate.number === selection.number);
  if (!item) {
    if (selection.number !== undefined) {
      throw new Error(`--show ${selection.number}: no such row (valid: 1..${model.totalRows})`);
    }
    throw new Error(`selected row is no longer present: ${selection.identity}`);
  }
  return renderExpandedItem(item);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function htmlRow(item) {
  return `<li class="row${item.attentionClass === "aged" ? " row-aged" : ""}">
    <span class="row-number">${item.number}</span>
    <span class="row-id">${escapeHtml(item.identity)}</span>
    <span class="marker marker-${escapeHtml(item.markerKey)}" aria-label="${escapeHtml(item.marker.label)}">${escapeHtml(item.marker.glyph)}</span>
    <span class="row-title">${escapeHtml(item.listLabel ?? item.name ?? "detail absent")}</span>
  </li>`;
}

function emptyState(message) {
  return `<li class="empty">${escapeHtml(message)}</li>`;
}

function sourceValue(label, value) {
  return `<div class="source"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderHtml(model) {
  const featured = recapFeaturedItems(model.recap);
  const hiddenRecap = model.recap.needsPedro.length + model.recap.stuck.length - featured.length;
  const recap = !model.recap.available
    ? '<p class="muted">Unknown - backlog source absent.</p>'
    : model.recap.needsPedro.length === 0 && model.recap.stuck.length === 0
      ? "<p>Nothing needs Pedro.</p>"
      : [
          `<p><strong>${[
            model.recap.needsPedro.length > 0 ? recapNeedsPedroLabel(model.recap) : null,
            model.recap.stuck.length > 0 ? `${model.recap.stuck.length} stuck` : null,
          ].filter(Boolean).join(" | ")}</strong></p>`,
          ...featured.map((item) => `<p><strong class="marker marker-${escapeHtml(item.markerKey)}">${escapeHtml(item.marker.glyph)}</strong> ${escapeHtml(item.name)}</p>`),
          hiddenRecap > 0 ? `<p class="muted">+${hiddenRecap} more below</p>` : "",
        ].filter(Boolean).join("\n    ");
  const sections = model.buckets
    .map(
      (bucket) => `<section id="${bucket.key}">
    <div class="section-head"><h2>${escapeHtml(bucket.htmlTitle)}</h2><p>${bucket.items.length} item${bucket.items.length === 1 ? "" : "s"}</p></div>
    <ol class="rows">${bucket.items.map((item) => htmlRow(item)).join("") || emptyState(bucket.empty)}</ol>
  </section>`,
    )
    .join("\n\n  ");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Firstmate Fleet Dashboard</title>
  <style>
    :root { color-scheme: dark; --bg:#101214; --line:#30343a; --text:#f2f0e8; --muted:#a6a9ad; --yellow:#e2a84a; --green:#6dbb91; --red:#e36d69; --blue:#6da5d9; --unknown:#c797d8; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { width:min(760px,calc(100% - 32px)); margin:0 auto; padding:40px 0 72px; }
    header { display:grid; gap:8px; margin-bottom:24px; }
    h1,h2,p { margin:0; }
    h1 { font-size:clamp(2rem,5vw,3.25rem); line-height:1; letter-spacing:-.04em; }
    h2 { font-size:.78rem; letter-spacing:.09em; text-transform:uppercase; }
    .lede,.stamp,.empty,.muted { color:var(--muted); }
    .sources { display:flex; flex-wrap:wrap; gap:8px 18px; margin:18px 0 28px; color:var(--muted); font-size:.8rem; }
    .source { display:flex; gap:6px; }
    .source span { text-transform:uppercase; letter-spacing:.06em; }
    .recap { display:grid; gap:6px; margin:0 0 28px; }
    .recap h2 { color:var(--muted); }
    section { padding:22px 0; border-top:1px solid var(--line); }
    .section-head { display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:10px; color:var(--muted); }
    .section-head p { color:var(--muted); }
    .rows { display:grid; gap:2px; margin:0; padding:0; list-style:none; }
    .row { min-width:0; display:grid; grid-template-columns:3ch max-content 2ch minmax(0,1fr); gap:8px; align-items:baseline; padding:5px 0; }
    .row-number,.row-id { color:var(--muted); font-variant-numeric:tabular-nums; }
    .row-number { text-align:right; }
    .row-title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .row-aged .row-title { color:var(--muted); }
    .marker { font-weight:800; }
    .marker-yellow { color:var(--yellow); }
    .marker-red { color:var(--red); }
    .marker-blue { color:var(--blue); }
    .marker-green { color:var(--green); }
    .marker-unknown { color:var(--unknown); }
    .legend { display:flex; flex-wrap:wrap; gap:6px 16px; padding-top:20px; border-top:1px solid var(--line); color:var(--muted); font-size:.8rem; }
    .empty { color:var(--muted); }
    @media (max-width:560px) { main { width:min(100% - 20px,760px); padding-top:24px; } }
  </style>
</head>
<body>
<main>
  <header>
    <p class="eyebrow">Firstmate · live state projection</p>
    <h1>Fleet Dashboard</h1>
    <p class="lede">Decisions first; everything else is review flow.</p>
    <p class="stamp">Observed ${escapeHtml(model.generated)} | ${escapeHtml(githubAgeLine(model.github, Date.now()))}</p>
  </header>

  <div class="sources" aria-label="Source availability">
    ${sourceValue("Backlog source", model.backlogPresent ? "Present" : "Absent")}
    ${sourceValue("Model telemetry", model.telemetryPresent ? "Present" : "Absent")}
    ${sourceValue("Token spend", "Not measured")}
  </div>

  <div class="recap">
    <h2>Attention now</h2>
    ${recap}
  </div>

  ${sections}

  <p class="legend">
    ${Object.entries(MARKERS).map(([key, marker]) => `<span><strong class="marker marker-${key}">${escapeHtml(marker.glyph)}</strong> ${escapeHtml(marker.label)}</span>`).join("")}
  </p>
</main>
</body>
</html>
`;
}

function collectLocalInputs() {
  const snapshotText = run(resolve(scriptDirectory, "fm-fleet-snapshot.sh"), ["--json"]);
  let snapshot;
  try {
    snapshot = JSON.parse(snapshotText);
  } catch {
    throw new Error("fm-fleet-snapshot.sh returned malformed JSON");
  }

  const telemetryPresent = existsSync(telemetryPath);
  let telemetryRows = null;
  if (telemetryPresent) {
    const telemetryText = run(resolve(scriptDirectory, "fm-model-telemetry.sh"), [
      "sheet",
      "--format",
      "json",
    ]);
    try {
      telemetryRows = JSON.parse(telemetryText);
    } catch {
      throw new Error("fm-model-telemetry.sh returned malformed JSON");
    }
  }

  const reviews = collectReviewRelationships();
  return { snapshot, telemetryRows, telemetryPresent, reviews };
}

function githubPrUrls(inputs) {
  const records = Array.isArray(inputs.snapshot.backlog?.records) ? inputs.snapshot.backlog.records : [];
  const completed = new Set(
    records.filter((record) => record.structured && record.id && record.state === "done").map((record) => record.id),
  );
  const ours = (inputs.snapshot.tasks || [])
    .filter(
      (task) =>
        task.kind !== "secondmate" && task.pr?.url && task.pr?.source === "meta" && !completed.has(task.id),
    )
    .map((task) => task.pr.url);
  const theirs = (inputs.reviews.relationships || []).map((relationship) => relationship.link).filter(Boolean);
  return [...new Set([...ours, ...theirs])];
}

function writeAtomically(outputPath, html) {
  mkdirSync(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.tmp-${process.pid}`;
  try {
    writeFileSync(temporaryPath, html, { encoding: "utf8", mode: 0o644 });
    renameSync(temporaryPath, outputPath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

// Internal loop rather than external watch(1) because the GitHub cache must
// survive between redraws; two cadences so forge polling stays slow while
// local file-derived state stays fresh. The alternate screen buffer keeps
// scrollback intact and home-then-erase redraws avoid flicker.
function watchLoop(width, useColor, showAll) {
  if (!process.stdout.isTTY || !process.stdin.isTTY) {
    throw new Error("--watch requires a terminal with interactive input");
  }
  emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdout.write("\u001b[?1049h\u001b[?25l");
  process.on("exit", () => {
    if (process.stdin.isRaw) process.stdin.setRawMode(false);
    process.stdout.write("\u001b[?25h\u001b[?1049l");
  });
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));

  let github = null;
  let model = null;
  let selectedIdentity = null;
  let input = "";
  let inputError = null;
  let refreshTimer = null;

  const draw = () => {
    if (!model) return;
    const frameWidth = width ?? process.stdout.columns ?? 80;
    let body;
    if (selectedIdentity !== null) {
      body = expandRow(model, { identity: selectedIdentity });
      body += "\nb or escape: back | q: exit\n";
    } else {
      body = renderTerminal(model, frameWidth, useColor, showAll, Date.now());
      const prompt = inputError ?? (input ? `select row: ${input}_ then Enter` : "select: type row number + Enter | q: exit");
      body += `${useColor ? ANSI.dim : ""}${clip(prompt, Math.min(frameWidth, 80))}${useColor ? ANSI.reset : ""}\n`;
    }
    process.stdout.write(`\u001b[H${body}\u001b[J`);
  };

  const frame = () => {
    try {
      const inputs = collectLocalInputs();
      if (github === null || secondsSince(github.fetchedAtMs, Date.now()) >= WATCH_GITHUB_SECONDS) {
        github = fetchGithubStatuses(githubPrUrls(inputs));
      }
      model = buildModel({ ...inputs, github });
      if (
        selectedIdentity !== null &&
        !model.buckets.flatMap((bucket) => bucket.items).some((item) => item.identity === selectedIdentity)
      ) {
        selectedIdentity = null;
      }
      draw();
    } catch (error) {
      process.stdout.write(`\u001b[Hfm-fleet-dashboard: ${error.message}\n\u001b[J`);
    }
    refreshTimer = setTimeout(frame, WATCH_LOCAL_SECONDS * 1000);
  };

  process.stdin.on("keypress", (_character, key) => {
    if ((key?.ctrl && key.name === "c") || key?.name === "q") process.exit(0);
    if (selectedIdentity !== null) {
      if (key?.name === "b" || key?.name === "escape") {
        selectedIdentity = null;
        inputError = null;
        draw();
      }
      return;
    }
    if (/^\d$/.test(key?.sequence ?? "")) {
      input = `${input}${key.sequence}`.replace(/^0+/, "").slice(0, String(model?.totalRows ?? 0).length || 1);
      inputError = null;
      draw();
      return;
    }
    if (key?.name === "backspace") {
      input = input.slice(0, -1);
      inputError = null;
      draw();
      return;
    }
    if (key?.name === "return") {
      const candidate = Number.parseInt(input, 10);
      if (Number.isInteger(candidate) && candidate >= 1 && candidate <= (model?.totalRows ?? 0)) {
        selectedIdentity = model.buckets
          .flatMap((bucket) => bucket.items)
          .find((item) => item.number === candidate).identity;
        input = "";
        inputError = null;
      } else {
        inputError = `no such row: ${input || "empty"}`;
        input = "";
      }
      draw();
    }
  });

  process.on("exit", () => clearTimeout(refreshTimer));
  frame();
}

try {
  const { outputPath, width, showAll, showRow, watch } = parseArguments(process.argv.slice(2));
  if (outputPath !== null) {
    assertSafeOutput(outputPath);
  }
  if (watch) {
    watchLoop(width, process.env.NO_COLOR ? false : true, showAll);
  } else {
    const inputs = collectLocalInputs();
    const urls = githubPrUrls(inputs);
    const github = urls.length > 0 ? fetchGithubStatuses(urls) : null;
    const model = buildModel({ ...inputs, github });
    if (showRow !== null) {
      process.stdout.write(expandRow(
        model,
        typeof showRow === "number" ? { number: showRow } : { identity: showRow },
      ));
    } else if (outputPath !== null) {
      writeAtomically(outputPath, renderHtml(model));
      process.stdout.write(`${outputPath}\n`);
    } else {
      const terminalWidth = width ?? (process.stdout.isTTY ? process.stdout.columns : null) ?? 80;
      const useColor = process.env.NO_COLOR
        ? false
        : Boolean(process.stdout.isTTY) || Boolean(process.env.FORCE_COLOR);
      process.stdout.write(renderTerminal(model, terminalWidth, useColor, showAll));
    }
  }
} catch (error) {
  process.stderr.write(`fm-fleet-dashboard: ${error.message}\n`);
  process.exit(1);
}
