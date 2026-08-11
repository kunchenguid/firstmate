#!/usr/bin/env node
// Render the Firstmate fleet cockpit from live state.
//
// The cockpit shows exactly three things, in Pedro's priority order:
//   1. DECISIONS he must take now, most important first, with the ranking
//      rule printed on screen.
//   2. OUR PRS IN REVIEW, each with the status he acts on and its full link.
//   3. REVIEWING - colleague PRs the reviews domain has rounds on.
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

function usage(stream = process.stdout) {
  stream.write(`usage: fm-fleet-dashboard.mjs [--width <columns>] [--all] [--show <row>] [--watch] [--output <path>]

Render the fleet cockpit: decisions ranked by importance, our PRs in
review with actionable status, and the reviews domain's open rounds.
--width <columns>  terminal width override (default: tty width, else 80)
--all              list every item; default caps each section
--show <row>       print one row's full context by its rendered row number
--watch            live redraw: local state every ${WATCH_LOCAL_SECONDS}s, GitHub state every
                   ${WATCH_GITHUB_SECONDS}s with its age printed (needs a terminal; ctrl-c exits)
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
      showRow = Number.parseInt(argumentsList[index + 1], 10);
      if (!Number.isInteger(showRow) || showRow < 1) {
        throw new Error("--show requires a positive row number");
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

function collectReviewRounds() {
  const domain = findReviewsDomain();
  if (!domain.available) {
    return { available: false, reason: domain.reason, rounds: [] };
  }
  if (!existsSync(domain.home)) {
    return { available: false, reason: `reviews home is gone: ${domain.home}`, rounds: [] };
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
    return { available: false, reason: `reviews home unreadable: ${error.message}`, rounds: [] };
  }
  if (snapshot.backlog?.present !== true) {
    return { available: false, reason: "reviews home has no backlog", rounds: [] };
  }
  const rounds = [];
  for (const record of snapshot.backlog.records || []) {
    if (!record.structured || record.state === "done") {
      continue;
    }
    let status = "round under way";
    if (record.hold_reason) {
      status = cleanProse(record.hold_reason);
    } else if (record.unresolved_blocker_ids?.length) {
      status = `queued behind ${record.unresolved_blocker_ids.join(", ")}`;
    } else if (record.state === "queued") {
      status = "round queued";
    }
    rounds.push({
      id: record.id,
      name: cleanProse(record.title) || record.id,
      project: record.repo ?? null,
      link: record.pr_url ?? record.links?.[0] ?? null,
      status,
      raw: record.raw,
      since: record.since ?? null,
    });
  }
  return { available: true, reason: null, home: domain.home, id: domain.id, rounds };
}

function githubStatusLabel(data) {
  if (data.state === "MERGED") return "merged";
  if (data.state === "CLOSED") return "closed";
  const checks = Array.isArray(data.statusCheckRollup) ? data.statusCheckRollup : [];
  const ciRed = checks.some((check) =>
    ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED"].includes(check.conclusion),
  );
  const ciRunning = checks.some(
    (check) => check.conclusion == null || ["IN_PROGRESS", "QUEUED", "PENDING"].includes(check.status),
  );
  if (data.mergeable === "CONFLICTING") return "resolving conflicts needed";
  if (data.reviewDecision === "CHANGES_REQUESTED") return "changes requested";
  if (ciRed) return "CI red";
  if (ciRunning) return "CI running";
  if (data.reviewDecision === "APPROVED") return "approved - ready to merge";
  return "CI green - waiting on human review";
}

// GitHub state is fetched on its own slow cadence because it is expensive and
// rate-limited, and its age is always printed so a cached CI result is never
// read as live.
function fetchGithubStatuses(urls) {
  const results = new Map();
  let error = null;
  for (const url of urls.slice(0, GITHUB_PR_LIMIT)) {
    if (!/^https:\/\/github\.com\//.test(url)) {
      results.set(url, { ok: false, status: "status unavailable (not a github.com PR)" });
      continue;
    }
    try {
      const text = run("gh", [
        "pr",
        "view",
        url,
        "--json",
        "state,mergeable,reviewDecision,statusCheckRollup",
      ]);
      results.set(url, { ok: true, status: githubStatusLabel(JSON.parse(text)) });
    } catch (fetchError) {
      results.set(url, { ok: false, status: "github unavailable" });
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
  const blockingDeliveryIds = new Set(records.flatMap((record) => record.unresolved_blocker_ids || []));

  const decisions = [];
  const ours = [];
  const reviewing = [];

  for (const record of records) {
    if (!record.structured || record.state === "done") {
      continue;
    }
    if (record.hold_kind === "captain" && record.hold_reason && !record.unresolved_blocker_ids?.length) {
      decisions.push({
        tag: "HOLD",
        name: cleanProse(record.title) || record.id,
        id: record.id,
        project: record.repo ?? null,
        prose: cleanProse(record.hold_reason),
        note: null,
        age: sinceAge(record.since),
        live: false,
        raw: record.raw,
        why: "captain hold with no unresolved blockers - only Pedro can clear it",
      });
    }
  }

  for (const task of tasks) {
    const telemetry = telemetryForTask(task, telemetryRows, observedMilliseconds);
    const itemAge = taskAge(task, telemetry, observedMilliseconds);
    const state = task.current_state?.state || "unknown";
    const detail = cleanProse(task.current_state?.detail);
    const base = {
      name: titleById.get(task.id) || task.id,
      id: task.id,
      project: task.project || null,
      age: itemAge,
      live: task.endpoint?.exists === true,
      statusLog: task.paths?.status_log?.present ? task.paths.status_log.path : null,
      pr: task.pr?.url ? task.pr : null,
      report: task.paths?.report?.present ? task.paths.report.path : null,
      worktree: task.paths?.worktree?.path ?? null,
    };
    const openDecisions = task.hints?.open_decisions || [];
    for (const decision of openDecisions.filter((entry) => entry.verb === "needs-decision")) {
      decisions.push({
        ...base,
        tag: "DECIDE",
        prose: cleanProse(decision.summary) || "decision summary absent",
        note: decision.key && decision.key !== "default" ? `[${decision.key}]` : null,
        why: "open needs-decision in the keyed decision fold, not yet resolved",
      });
    }
    for (const blocker of openDecisions.filter((entry) => entry.verb === "blocked")) {
      decisions.push({
        ...base,
        tag: "BLOCKED",
        prose: cleanProse(blocker.summary) || "blocker summary absent",
        note: blocker.key && blocker.key !== "default" ? `[${blocker.key}]` : null,
        why: "open blocked event in the keyed decision fold, not yet resolved",
      });
    }
    if (openDecisions.length === 0 && state === "blocked") {
      decisions.push({
        ...base,
        tag: "BLOCKED",
        prose: detail || "blocked, no detail reported",
        note: null,
        why: "reconciled current state is blocked",
      });
    }

    // Only pr= recorded in task metadata is a live PR of ours; URLs parsed
    // out of status prose are history, and a backlog completion means landed.
    if (task.kind !== "secondmate" && task.pr?.url && task.pr?.source === "meta" && !completedIds.has(task.id)) {
      const lastEvent = cleanProse(task.hints?.last_event_text).replaceAll(/https?:\/\/\S+/g, "").trim();
      const recorded = detail || lastEvent || "no status recorded";
      const githubResult = github?.results?.get(task.pr.url) ?? null;
      ours.push({
        ...base,
        tag: "OURS",
        prose: githubResult ? githubResult.status : `not checked on github - last recorded: ${recorded}`,
        note: task.pr.url,
        why: "our PR recorded in task metadata and not yet landed in the backlog",
      });
    }
  }

  for (const round of reviews.rounds) {
    reviewing.push({
      tag: "THEIRS",
      name: round.name,
      id: round.id,
      project: round.project,
      prose: round.status,
      note: round.link ?? "link not recorded in the round",
      age: sinceAge(round.since),
      live: false,
      raw: round.raw,
      why: "open review round recorded in the reviews domain's own backlog",
    });
  }

  // The printed ranking rule: a decision a person is waiting on right now
  // outranks one blocking queued delivery, which outranks pure age.
  const importanceTier = (item) => {
    if ((item.tag === "DECIDE" || item.tag === "BLOCKED") && item.live) return 0;
    if (blockingDeliveryIds.has(item.id)) return 1;
    return 2;
  };
  const oldestFirst = (left, right) => (right.age.seconds ?? -1) - (left.age.seconds ?? -1);
  decisions.sort((left, right) => importanceTier(left) - importanceTier(right) || oldestFirst(left, right));
  ours.sort(oldestFirst);
  reviewing.sort(oldestFirst);

  const model = {
    generated: snapshot.generated || "observation time absent",
    backlogPresent,
    telemetryPresent,
    reviews,
    github,
    buckets: [
      {
        key: "decisions",
        name: "DECISIONS",
        htmlTitle: "Decisions",
        tone: "attention",
        items: decisions,
        cap: 6,
        rule: "rule: blocking a person, then blocking delivery, then oldest",
        empty: backlogPresent ? "nothing needs a decision" : "backlog absent - captain holds unknown",
      },
      {
        key: "ours-in-review",
        name: "OUR PRS IN REVIEW",
        htmlTitle: "Our PRs in review",
        tone: "progress",
        items: ours,
        cap: 5,
        empty: "no PR of ours recorded in review",
      },
      {
        key: "reviewing",
        name: "REVIEWING",
        htmlTitle: "Reviewing",
        tone: "neutral",
        items: reviewing,
        cap: 5,
        empty: reviews.available ? "no open review rounds" : `unavailable - ${reviews.reason}`,
      },
    ],
  };

  let rowNumber = 0;
  for (const bucket of model.buckets) {
    for (const item of bucket.items) {
      rowNumber += 1;
      item.number = rowNumber;
      item.bucketName = bucket.name;
    }
  }
  model.totalRows = rowNumber;
  return model;
}

const ANSI = { reset: "\u001b[0m", dim: "\u001b[2m", accent: "\u001b[33m", accentBold: "\u001b[1;33m" };
const AGE_HOT_SECONDS = 7 * 86400;

function clip(text, width) {
  return text.length <= width ? text : `${text.slice(0, Math.max(0, width - 1))}…`;
}

function ageText(item) {
  return item.age.seconds !== null && item.age.seconds >= AGE_HOT_SECONDS
    ? `⚠ ${item.age.label}`
    : item.age.label;
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

function renderTerminal(model, width, useColor, showAll, nowMs = Date.now()) {
  const paint = (name, text) => (useColor && name ? `${ANSI[name]}${text}${ANSI.reset}` : text);
  const lines = [];
  lines.push(paint("dim", clip(`FIRSTMATE FLEET · observed ${model.generated}`, width)));
  lines.push(
    paint(
      "dim",
      clip(
        `sources: backlog ${model.backlogPresent ? "present" : "absent"} · telemetry ${model.telemetryPresent ? "present" : "absent"} · token spend not measured`,
        width,
      ),
    ),
  );
  let firstBucket = true;
  for (const bucket of model.buckets) {
    lines.push("");
    if (!firstBucket) {
      lines.push("");
    }
    firstBucket = false;
    const isAccentBucket = bucket.key === "decisions";
    const rule = isAccentBucket ? "━" : "─";
    const header = `${rule}${rule} ${bucket.name} (${bucket.items.length}) `;
    const fill = rule.repeat(Math.max(0, width - header.length));
    lines.push(paint(isAccentBucket ? "accentBold" : "dim", clip(header + fill, width)));
    if (bucket.key === "ours-in-review") {
      lines.push(paint("dim", clip(`   ${githubAgeLine(model.github, nowMs)}`, width)));
    }
    if (bucket.items.length === 0) {
      lines.push(paint("dim", clip(`   ${bucket.empty}`, width)));
      continue;
    }
    const shown = showAll ? bucket.items : bucket.items.slice(0, bucket.cap);
    const numberWidth = String(model.totalRows).length;
    const headIndent = 2 + numberWidth + 1 + 8;
    for (const item of shown) {
      const tag = clip(item.tag, 7).padEnd(7);
      const rowLabel = String(item.number).padStart(numberWidth);
      const itemAge = ageText(item);
      const mid = [item.name, item.project].filter(Boolean).join(" · ");
      const midWidth = Math.max(8, width - headIndent - 3 - itemAge.length);
      lines.push(
        `  ${paint("dim", rowLabel)} ${paint(isAccentBucket ? "accent" : "dim", tag)} ${clip(mid, midWidth)} · ${paint("dim", itemAge)}`,
      );
      const detail = [item.prose, item.note].filter(Boolean).join("  ");
      if (detail) {
        lines.push(paint("dim", `${" ".repeat(headIndent)}${clip(detail, Math.max(0, width - headIndent))}`));
      }
    }
    const hidden = bucket.items.length - shown.length;
    if (hidden > 0) {
      const ruleText = bucket.rule ? ` · ${bucket.rule}` : "";
      lines.push(paint("dim", clip(`  … ${hidden} more${ruleText} · --all shows all`, width)));
    } else if (bucket.rule && bucket.items.length > 1) {
      lines.push(paint("dim", clip(`  ${bucket.rule}`, width)));
    }
  }
  return `${lines.join("\n")}\n`;
}

// Full single-item context for --show <n>: nothing truncated, every field
// sourced from data the cockpit already read.
function renderShow(model, requestedNumber) {
  const item = model.buckets
    .flatMap((bucket) => bucket.items)
    .find((candidate) => candidate.number === requestedNumber);
  if (!item) {
    throw new Error(`--show ${requestedNumber}: no such row (valid: 1..${model.totalRows})`);
  }
  const lines = [];
  lines.push(`#${item.number} · ${item.bucketName} · ${item.tag}`);
  lines.push(item.name || "(unnamed)");
  lines.push("");
  if (item.prose) {
    lines.push(`detail: ${item.prose}`);
  }
  if (item.note) {
    lines.push(`note: ${item.note}`);
  }
  lines.push(`age: ${item.age.label}`);
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

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function card(item, tone) {
  const detailParts = [item.prose, item.note].filter(Boolean);
  const detailMarkup = detailParts.length
    ? `<span>${detailParts.map((part) => escapeHtml(part)).join(" &middot; ")}</span>`
    : "";
  const hot = item.age.seconds !== null && item.age.seconds >= AGE_HOT_SECONDS;
  return `<article class="card ${escapeHtml(tone)}">
    <p class="eyebrow">${escapeHtml([`#${item.number}`, item.tag, item.project].filter(Boolean).join(" · "))}</p>
    <h3>${escapeHtml(item.name || "detail absent")}</h3>
    <div class="runtime"><strong class="age-${hot ? "hot" : "calm"}">${escapeHtml((hot ? "⚠ " : "") + item.age.label)}</strong>${detailMarkup}</div>
  </article>`;
}

function emptyState(message) {
  return `<p class="empty">${escapeHtml(message)}</p>`;
}

function sourceValue(label, value) {
  return `<div class="source"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderHtml(model) {
  const sections = model.buckets
    .map(
      (bucket) => `<section id="${bucket.key}">
    <div class="section-head"><h2>${escapeHtml(bucket.htmlTitle)}</h2><p>${bucket.items.length} item${bucket.items.length === 1 ? "" : "s"}</p></div>
    ${bucket.key === "ours-in-review" ? `<p class="stamp">${escapeHtml(githubAgeLine(model.github, Date.now()))}</p>` : ""}
    <div class="grid">${bucket.items.map((item) => card(item, bucket.tone)).join("") || emptyState(bucket.empty)}</div>
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
    :root { color-scheme: dark; --bg:#101214; --panel:#191c20; --line:#30343a; --text:#f2f0e8; --muted:#a6a9ad; --amber:#e2a84a; --green:#6dbb91; --red:#e36d69; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { width:min(1120px,calc(100% - 32px)); margin:0 auto; padding:40px 0 72px; }
    header { display:grid; gap:12px; margin-bottom:28px; }
    h1,h2,h3,p { margin:0; }
    h1 { font-size:clamp(2rem,5vw,4rem); line-height:1; letter-spacing:-.05em; }
    h2 { font-size:clamp(1.35rem,3vw,2rem); letter-spacing:-.025em; }
    h3 { font-size:1.05rem; overflow-wrap:anywhere; }
    .lede,.stamp,.empty,.card>p { color:var(--muted); }
    .sources { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:1px; margin:28px 0; border:1px solid var(--line); background:var(--line); }
    .source { min-width:0; display:flex; flex-direction:column; gap:4px; padding:14px; background:var(--panel); }
    .source span { color:var(--muted); font-size:.75rem; text-transform:uppercase; letter-spacing:.08em; }
    section { padding:28px 0; border-top:1px solid var(--line); }
    .section-head { display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:16px; }
    .section-head p { color:var(--muted); }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr)); gap:12px; }
    .card { min-width:0; display:grid; gap:10px; padding:18px; border:1px solid var(--line); border-top:3px solid var(--line); background:var(--panel); }
    .card.attention { border-top-color:var(--amber); }
    .card.progress { border-top-color:var(--green); }
    .card.danger { border-top-color:var(--red); }
    .eyebrow { font-size:.72rem; text-transform:uppercase; letter-spacing:.08em; overflow-wrap:anywhere; }
    .runtime { display:flex; flex-direction:column; gap:2px; padding-top:8px; border-top:1px solid var(--line); }
    .runtime span { color:var(--muted); font-size:.8rem; overflow-wrap:anywhere; }
    .age-hot { color:var(--red); }
    .empty { padding:18px; border:1px dashed var(--line); }
    @media (max-width:560px) { main { width:min(100% - 20px,1120px); padding-top:24px; } .section-head { display:grid; } }
  </style>
</head>
<body>
<main>
  <header>
    <p class="eyebrow">Firstmate · live state projection</p>
    <h1>Fleet Dashboard</h1>
    <p class="lede">Decisions first; everything else is review flow.</p>
    <p class="stamp">Observed ${escapeHtml(model.generated)}</p>
  </header>

  <div class="sources" aria-label="Source availability">
    ${sourceValue("Backlog source", model.backlogPresent ? "Present" : "Absent")}
    ${sourceValue("Model telemetry", model.telemetryPresent ? "Present" : "Absent")}
    ${sourceValue("Token spend", "Not measured")}
  </div>

  ${sections}
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

  const reviews = collectReviewRounds();
  return { snapshot, telemetryRows, telemetryPresent, reviews };
}

function ourPrUrls(inputs) {
  const records = Array.isArray(inputs.snapshot.backlog?.records) ? inputs.snapshot.backlog.records : [];
  const completed = new Set(
    records.filter((record) => record.structured && record.id && record.state === "done").map((record) => record.id),
  );
  return (inputs.snapshot.tasks || [])
    .filter(
      (task) =>
        task.kind !== "secondmate" && task.pr?.url && task.pr?.source === "meta" && !completed.has(task.id),
    )
    .map((task) => task.pr.url);
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
  if (!process.stdout.isTTY) {
    throw new Error("--watch requires a terminal");
  }
  process.stdout.write("\u001b[?1049h\u001b[?25l");
  process.on("exit", () => {
    process.stdout.write("\u001b[?25h\u001b[?1049l");
  });
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));

  let github = null;
  const frame = () => {
    let body;
    try {
      const inputs = collectLocalInputs();
      if (github === null || secondsSince(github.fetchedAtMs, Date.now()) >= WATCH_GITHUB_SECONDS) {
        github = fetchGithubStatuses(ourPrUrls(inputs));
      }
      const model = buildModel({ ...inputs, github });
      const frameWidth = width ?? process.stdout.columns ?? 80;
      body = renderTerminal(model, frameWidth, useColor, showAll, Date.now());
      body += `\n${useColor ? ANSI.dim : ""}watch: local every ${WATCH_LOCAL_SECONDS}s · github every ${WATCH_GITHUB_SECONDS}s · ctrl-c exits${useColor ? ANSI.reset : ""}\n`;
    } catch (error) {
      body = `fm-fleet-dashboard: ${error.message}\n`;
    }
    process.stdout.write(`\u001b[H${body}\u001b[J`);
    setTimeout(frame, WATCH_LOCAL_SECONDS * 1000);
  };
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
    const urls = ourPrUrls(inputs);
    const github = urls.length > 0 ? fetchGithubStatuses(urls) : null;
    const model = buildModel({ ...inputs, github });
    if (showRow !== null) {
      process.stdout.write(renderShow(model, showRow));
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
