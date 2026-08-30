#!/usr/bin/env node
// Render the Firstmate fleet cockpit from live state.
//
// The default cockpit shows exactly three things, in Pedro's priority order:
//   1. DECISIONS he must take now.
//   2. OUR PRS IN REVIEW.
//   3. REVIEWING - colleague PR relationships recorded by the reviews domain.
// An explicit building section also shows in-flight tasks that have neither a
// PR nor an open decision, while the no-selector display remains unchanged.
// --section peace projects the existing record-contradiction digest and
// unadvanceable-work detector as one records line and adds no other numbers.
// That line carries exactly three verdicts:
//   records: agree                                both instruments ran and are silent
//   records: disagree (N ghost, M stranded)       at least one instrument found a contradiction
//   records: unknown (ghost unknown, 0 stranded)  nothing found and an instrument could not run
// The third verdict, unknown, exists because an instrument that cannot answer
// has to say so: reading its silence as agreement would report invented health,
// and failing the whole section would drop the half that did answer. Either
// half spells its own count unknown rather than 0 when it could not run, so
// disagree outranks unknown whenever the answering half found something:
// `records: disagree (N ghost, stranded unknown)`.
// Peace skips the cockpit's own forge fetch, but it is not an offline section:
// the digest half inherits its owner's bounded gh-axi PR checks for metas that
// record a PR, so peace reaches GitHub exactly when and as far as that owner
// does. Those calls are uncached and per-collect, so watch mode refreshes the
// records line on the same slow WATCH_GITHUB_SECONDS cadence as the forge
// fetch it skips, never on the fast local frame. The strandedness half is
// bounded by UNADVANCEABLE_WORK_TIMEOUT_MS, which covers the detector's serial
// per-crew liveness probes (each bounded in turn by fm-crew-state.sh's own
// no-mistakes timeout). The digest half gets no constant from this file: the
// owner's own time limits bound its gh-axi calls alone, and the collect as a
// whole takes run's default 60000 ms bound. Both halves degrade when
// unavailable. The strandedness half can be unavailable because the tasks-axi
// backlog backend is disabled or because its liveness probes outlast their
// bound. The digest half can be unavailable because its collector or a
// required dependency fails, or because the collect outlasts that bound. Each
// carries its unknown spelling on the records value, so the line itself is
// symmetric. Unavailability is still the only digest failure this line can
// see: inside a collect that does run, the owner swallows its own probe
// failures, counting a PR check that could not reach GitHub as no
// contradiction rather than as a refusal, so agree stays optimistic by exactly
// that much. The reasons are not symmetric yet: a one-shot render emits
// either half's reason to stderr as it collects, while the watch surface
// still routes only the strandedness reason, holding every distinct one until
// the alternate screen is torn down so a diagnostic can never paint over a
// live frame.
// The default is a fixed-measure one-line list; --show and watch selection own
// full context so titles never compete with status prose during a scan.
//
// Fleet sources stay read-only: fm-fleet-snapshot.sh (built on
// fm-crew-state.sh and fm-classify-lib.sh) owns meta/status/backlog
// classification for this home and for the reviews domain's home,
// fm-model-telemetry.sh owns its attempt sheet, and the gh CLI supplies forge
// state on a deliberately slow cadence with its data age printed plainly.
// The dashboard owns one operational write: state/fleet-dashboard-observations.json
// stores the explicit values last acknowledged through row expansion.
//
// Outputs:
//   default            one-shot ANSI terminal cockpit on stdout
//   --watch            live terminal loop; local state refreshes fast,
//                      GitHub state refreshes slowly and shows its age
//   --output <path>    self-contained HTML page (never under data/, state/,
//                      or config/)
//   observation store  seeded silently on first render; terminal expansion
//                      atomically acknowledges only the selected row

import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";
import { emitKeypressEvents } from "node:readline";
import { fileURLToPath } from "node:url";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const fleetHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || repositoryRoot);
const dataDirectory = resolve(process.env.FM_DATA_OVERRIDE || resolve(fleetHome, "data"));
const stateDirectory = resolve(process.env.FM_STATE_OVERRIDE || resolve(fleetHome, "state"));
const configDirectory = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(fleetHome, "config"));
const telemetryPath = resolve(dataDirectory, "routing-outcomes.jsonl");
const secondmatesPath = resolve(dataDirectory, "secondmates.md");
const observationStorePath = resolve(stateDirectory, "fleet-dashboard-observations.json");
const observationStoreLockPath = resolve(stateDirectory, ".fleet-dashboard-observations.lock");
const observationStoreRecoveryLockPath = resolve(stateDirectory, ".fleet-dashboard-observations-recovery.lock");

const WATCH_LOCAL_SECONDS = Number.parseInt(process.env.FM_FLEET_WATCH_LOCAL_SECONDS || "5", 10);
const WATCH_GITHUB_SECONDS = Number.parseInt(process.env.FM_FLEET_WATCH_GITHUB_SECONDS || "120", 10);
const requestedForgeTimeoutMs = Number.parseInt(process.env.FM_FLEET_FORGE_TIMEOUT_MS || "60000", 10);
const FORGE_REFRESH_TIMEOUT_MS = Number.isInteger(requestedForgeTimeoutMs) && requestedForgeTimeoutMs > 0
  ? requestedForgeTimeoutMs
  : 60000;
const GITHUB_OPTIONAL_PR_LIMIT = 6;
const REVIEW_REQUEST_LIMIT = 1000;
const REVIEW_REQUEST_TIMELINE_LIMIT = 20;
const READABLE_ID_LIMIT = 28;
const OBSERVATION_STORE_VERSION = 1;
const DEFAULT_BUCKET_LIMITS = Object.freeze({
  decisions: 2,
  building: 2,
  "ours-in-review": 2,
  "review-obligations": 2,
  reviewing: 1,
});
const DEFAULT_BUCKET_KEYS = Object.freeze([
  "decisions",
  "ours-in-review",
  "review-obligations",
  "reviewing",
]);
const SECTION_BUCKET_KEYS = Object.freeze({
  building: ["building", "ours-in-review"],
  approvals: ["decisions", "review-obligations"],
  reviewing: ["reviewing"],
  all: ["decisions", "building", "ours-in-review", "review-obligations", "reviewing"],
  peace: [],
});
const UNADVANCEABLE_WORK_TIMEOUT_MS = 180000;
const REVIEW_THREADS_QUERY = `
query FleetDashboardReviewThreads($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          resolvedBy { login }
          comments(first: 1) { nodes { author { login } createdAt } }
        }
      }
    }
  }
}`;
const MARKERS = Object.freeze({
  yellow: { glyph: "◆", label: "needs Pedro", color: "yellow" },
  red: { glyph: "×", label: "stuck", color: "red" },
  blue: { glyph: "○", label: "waiting elsewhere", color: "blue" },
  green: { glyph: "●", label: "progressing", color: "green" },
  unknown: { glyph: "?", label: "unknown", color: "magenta" },
});
const MARKER_PRIORITY = Object.freeze({ yellow: 0, red: 1, blue: 2, green: 3, unknown: 4 });

function usage(stream = process.stdout) {
  stream.write(`usage: fm-fleet-dashboard.mjs [--width <columns>] [--all] [--section <name>] [--show <row>] [--watch] [--output <path>]

Render the fleet cockpit: decisions ranked by importance, our PRs in
review with actionable status, and the reviews domain's PR relationships.
--width <columns>  terminal frame width request (minimum 40; output capped at 80)
--all              show deferred rows inside the selected view
--section <name>   render building, approvals, reviewing, peace, or all; omitted keeps the default
--show <row|id>    print one row's full context by position or exact stable id;
                   append * to request an unambiguous id-prefix match; expansion
                   marks only that row's current watched values seen
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
  let section = null;
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
    if (argument === "--section") {
      const supplied = argumentsList[index + 1];
      if (!Object.hasOwn(SECTION_BUCKET_KEYS, supplied)) {
        throw new Error(`unknown section ${supplied ?? "(missing)"}; valid sections: ${Object.keys(SECTION_BUCKET_KEYS).join(", ")}`);
      }
      section = supplied;
      index += 1;
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
  return { outputPath, width, showAll, section, showRow, watch };
}

function sectionForgeMode(section) {
  if (section === "building" || section === "peace") return "none";
  if (section === "approvals") return "review-requests";
  return "full";
}

function skippedForgeState() {
  return {
    github: null,
    reviewRequests: {
      available: false,
      fetchedAtMs: null,
      viewer: null,
      items: [],
      reason: "not checked for local-only section",
    },
    quota: {
      available: false,
      fetchedAtMs: null,
      providers: [],
      reason: "not checked for local-only section",
    },
  };
}

function peaceRecordsLine(records) {
  if (!records) {
    throw new Error("peace records were not collected from the existing instruments");
  }
  if (records.ghost === 0 && records.stranded === 0) {
    return "records: agree";
  }
  const verdict = records.ghost > 0 || records.stranded > 0 ? "disagree" : "unknown";
  const ghost = records.ghost === null ? "ghost unknown" : `${records.ghost} ghost`;
  const stranded = records.stranded === null ? "stranded unknown" : `${records.stranded} stranded`;
  return `records: ${verdict} (${ghost}, ${stranded})`;
}

function contradictionTotalFromOwner(text) {
  const total = Number.parseInt(String(text).trim(), 10);
  if (!Number.isInteger(total) || total < 0) {
    throw new Error(`fm_record_contradictions_total returned a non-count: ${String(text).trim()}`);
  }
  return total;
}

function strandedCountFromUnadvanceable(text) {
  return String(text).split(/\r?\n/).filter((line) => line.trim() !== "").length;
}

async function collectContradictionTotal() {
  return contradictionTotalFromOwner(await run("/bin/bash", [
    "-c",
    '. "$1/fm-backend.sh" && . "$1/fm-pr-lib.sh" && . "$1/fm-record-contradictions-lib.sh" && fm_record_contradictions_total "$2" "$3"',
    "fm-record-contradictions-total",
    scriptDirectory,
    dataDirectory,
    stateDirectory,
  ]));
}

async function collectUnadvanceableWork() {
  return run(
    resolve(scriptDirectory, "fm-unadvanceable-work.sh"),
    [],
    process.env,
    UNADVANCEABLE_WORK_TIMEOUT_MS,
  );
}

async function collectPeaceRecords() {
  const [ghost, unadvanceable] = await Promise.all([
    collectContradictionTotal().then(
      (total) => ({ total }),
      (error) => ({ reason: error.message }),
    ),
    collectUnadvanceableWork().then(
      (text) => ({ text }),
      (error) => ({ reason: error.message }),
    ),
  ]);
  return {
    ghost: ghost.reason === undefined ? ghost.total : null,
    ghostReason: ghost.reason ?? null,
    stranded: unadvanceable.reason === undefined
      ? strandedCountFromUnadvanceable(unadvanceable.text)
      : null,
    strandedReason: unadvanceable.reason ?? null,
  };
}

function peaceDegradationLine(reason) {
  return `fm-fleet-dashboard: stranded unknown: ${reason}\n`;
}

function peaceOneShotDegradationLine(instrument, reason) {
  return `fm-fleet-dashboard: ${instrument} unknown: ${reason}\n`;
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

function run(command, argumentsList, environment = process.env, timeout = 60000, killProcessGroup = false) {
  return new Promise((resolvePromise, rejectPromise) => {
    let timedOut = false;
    const detached = killProcessGroup && process.platform !== "win32";
    const child = execFile(command, argumentsList, {
      detached,
      encoding: "utf8",
      env: environment,
      maxBuffer: 16 * 1024 * 1024,
    }, (error, stdout, stderr) => {
      clearTimeout(timeoutTimer);
      if (!error) {
        resolvePromise(stdout);
        return;
      }
      const diagnostic = stderr?.toString().trim() || error.message;
      const wrapped = new Error(`${command} failed: ${diagnostic}`);
      wrapped.timedOut = timedOut;
      rejectPromise(wrapped);
    });
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      try {
        if (detached && child.pid) process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }, timeout);
  });
}

function commandTimeout(deadlineMs, fallback = 60000) {
  if (!Number.isFinite(deadlineMs)) return fallback;
  return Math.max(1, Math.min(fallback, deadlineMs - Date.now()));
}

function markdownSection(text, names) {
  const wanted = new Set(names.map((name) => name.toLowerCase()));
  const lines = String(text ?? "").split(/\r?\n/);
  let headingLevel = null;
  const section = [];
  for (const line of lines) {
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*$/);
    if (headingLevel === null) {
      if (heading && wanted.has(heading[2].toLowerCase())) {
        headingLevel = heading[1].length;
      }
      continue;
    }
    if (heading && heading[1].length <= headingLevel) break;
    section.push(line);
  }
  const value = section.join("\n").trim();
  return value || null;
}

function reportEvidence(reportPath) {
  if (!reportPath || !existsSync(reportPath)) {
    return { impact: null, manualScript: null, manualScriptOmittedFromHtml: false };
  }
  let text;
  try {
    text = readFileSync(reportPath, "utf8");
  } catch {
    return { impact: null, manualScript: null, manualScriptOmittedFromHtml: false };
  }
  const manualScript = markdownSection(text, ["Manual test script", "Manual validation script"]);
  return {
    impact: markdownSection(text, ["What this affects", "User impact"]),
    manualScript,
    manualScriptOmittedFromHtml: manualScript !== null,
  };
}

async function fetchQuota(deadlineMs = null) {
  const fetchedAtMs = Date.now();
  try {
    const data = JSON.parse(await run(
      "quota-axi",
      ["--json"],
      process.env,
      commandTimeout(deadlineMs, 10000),
      Number.isFinite(deadlineMs),
    ));
    return {
      available: true,
      fetchedAtMs,
      generatedAt: data.generatedAt ?? null,
      providers: Array.isArray(data.providers) ? data.providers : [],
      reason: null,
    };
  } catch (error) {
    if (error.timedOut) throw error;
    return { available: false, fetchedAtMs, generatedAt: null, providers: [], reason: error.message.split("\n")[0] };
  }
}

async function fetchReviewRequests(deadlineMs = null) {
  const fetchedAtMs = Date.now();
  try {
    const viewer = (await run(
      "gh",
      ["api", "user", "--jq", ".login"],
      process.env,
      commandTimeout(deadlineMs),
      Number.isFinite(deadlineMs),
    )).trim();
    if (!viewer) throw new Error("authenticated GitHub login is unknown");
    const found = JSON.parse(await run("gh", [
      "search", "prs", "--review-requested=@me", "--state=open", "--limit", String(REVIEW_REQUEST_LIMIT),
      "--json", "author,createdAt,number,repository,title,updatedAt,url",
    ], process.env, commandTimeout(deadlineMs), Number.isFinite(deadlineMs)));
    const items = [];
    for (let index = 0; index < (Array.isArray(found) ? found.length : 0); index += 1) {
      const result = found[index];
      const repository = result.repository?.nameWithOwner ?? null;
      let requestedAt = null;
      if (repository && result.number && index < REVIEW_REQUEST_TIMELINE_LIMIT) {
        try {
          const requestedReviewers = JSON.parse(await run("gh", [
            "api", "--method", "GET", `repos/${repository}/pulls/${result.number}/requested_reviewers`,
          ], process.env, commandTimeout(deadlineMs), Number.isFinite(deadlineMs)));
          const viewerIsRequested = (requestedReviewers.users ?? [])
            .some((reviewer) => reviewer.login === viewer);
          const requestedTeamKeys = new Set((requestedReviewers.teams ?? []).flatMap((team) =>
            [team.id == null ? null : String(team.id), team.slug, team.name].filter(Boolean),
          ));
          const timeline = JSON.parse(await run("gh", [
            "api", "--method", "GET", `repos/${repository}/issues/${result.number}/timeline`, "-f", "per_page=100",
          ], process.env, commandTimeout(deadlineMs), Number.isFinite(deadlineMs)));
          const events = (Array.isArray(timeline) ? timeline : [])
            .filter((event) => {
              const requestedTeam = event.requested_team;
              const teamMatches = requestedTeam && [
                requestedTeam.id == null ? null : String(requestedTeam.id),
                requestedTeam.slug,
                requestedTeam.name,
              ].filter(Boolean).some((key) => requestedTeamKeys.has(key));
              return event.event === "review_requested" && event.created_at && (
                (viewerIsRequested && event.requested_reviewer?.login === viewer) || teamMatches
              );
            })
            .sort((left, right) => Date.parse(right.created_at) - Date.parse(left.created_at));
          requestedAt = events[0]?.created_at ?? null;
        } catch (error) {
          if (error.timedOut) throw error;
          requestedAt = null;
        }
      }
      items.push({ ...result, repositoryName: repository, requestedAt });
    }
    return { available: true, fetchedAtMs, viewer, items, reason: null };
  } catch (error) {
    if (error.timedOut) throw error;
    return { available: false, fetchedAtMs, viewer: null, items: [], reason: error.message.split("\n")[0] };
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

function projectLabel(value) {
  const label = cleanProse(value);
  if (!label) return null;
  return isAbsolute(label) ? basename(label) : label;
}

function readableRowId(prefix, stableValue, canonical, title, forceDiscriminator = false) {
  const normalize = (value) => String(value ?? "")
    .toLowerCase()
    .replaceAll(/[^a-z0-9]+/g, "-")
    .replaceAll(/^-+|-+$/g, "");
  let source = normalize(stableValue);
  let weak = false;
  if (!source || /^[0-9a-f]{12,}$/i.test(source)) {
    source = normalize(title) || "row";
    weak = true;
  }
  const natural = `${prefix}:${source}`;
  if (!forceDiscriminator && !weak && natural.length <= READABLE_ID_LIMIT) return natural;

  const discriminator = createHash("sha256").update(canonical).digest("hex").slice(0, 4);
  const available = Math.max(4, READABLE_ID_LIMIT - prefix.length - discriminator.length - 3);
  const parts = source.split("-").filter(Boolean);
  let readable = "";
  for (const part of parts) {
    const candidate = readable ? `${readable}-${part}` : part;
    if (candidate.length > available) break;
    readable = candidate;
  }
  if (!readable) readable = source.slice(0, available);
  return `${prefix}:${readable}~${discriminator}`;
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

async function githubPrUrlFromProjectRemote(home, project, number) {
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
    remote = (await run("git", ["-C", projectPath, "remote", "get-url", "origin"])).trim();
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

async function collectReviewRelationships() {
  const domain = findReviewsDomain();
  if (!domain.available) {
    return { available: false, reason: domain.reason, relationships: [] };
  }
  if (!existsSync(domain.home)) {
    return { available: false, reason: `reviews home is gone: ${domain.home}`, relationships: [] };
  }
  let snapshot;
  try {
    const text = await run(resolve(scriptDirectory, "fm-fleet-snapshot.sh"), ["--json"], {
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
      : await githubPrUrlFromProjectRemote(domain.home, current.repo, group.number);
    relationships.push({
      id: group.number ? `pr-${group.number}` : current.id,
      number: group.number,
      name: group.number ? `PR ${group.number}` : `PR unknown: ${cleanProse(current.title) || current.id}`,
      project: projectLabel(current.repo),
      link: recordedLink ?? derivedLink,
      linkSource: recordedLink ? "record" : derivedLink ? "verified_project_remote" : "absent",
      status,
      raw: records.map((record) => record.raw).filter(Boolean).join("\n"),
      since: recordActivityDate(records[0]),
      roundCount,
      heads: [...group.heads],
      workflowState: current.state ?? "unknown",
      holdReason: current.hold_reason ? cleanProse(current.hold_reason) : null,
    });
  }
  return { available: true, reason: null, home: domain.home, id: domain.id, relationships };
}

function githubStatus(data) {
  const checks = Array.isArray(data.statusCheckRollup) ? data.statusCheckRollup : [];
  const reviews = Array.isArray(data.reviews) ? data.reviews : null;
  const latestStateByAuthor = new Map();
  const latestActivityByAuthor = new Map();
  for (let index = 0; index < (reviews ?? []).length; index += 1) {
    const review = reviews[index];
    const author = review.author?.login ?? null;
    if (!author) continue;
    const submittedAtMs = Date.parse(review.submittedAt || "");
    const previousActivity = latestActivityByAuthor.get(author);
    const laterThanPreviousActivity = previousActivity && Number.isFinite(submittedAtMs) && Number.isFinite(previousActivity.submittedAtMs)
      ? submittedAtMs >= previousActivity.submittedAtMs
      : previousActivity && index > previousActivity.index;
    if (!previousActivity || laterThanPreviousActivity) {
      latestActivityByAuthor.set(author, { review, submittedAtMs, index });
    }
    if (!["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(review.state)) continue;
    const previous = latestStateByAuthor.get(author);
    const laterThanPrevious = previous && Number.isFinite(submittedAtMs) && Number.isFinite(previous.submittedAtMs)
      ? submittedAtMs >= previous.submittedAtMs
      : previous && index > previous.index;
    if (
      !previous ||
      laterThanPrevious
    ) {
      latestStateByAuthor.set(author, { review, submittedAtMs, index });
    }
  }
  const latestReviews = [...latestStateByAuthor.values()]
    .sort((left, right) => left.index - right.index)
    .map((entry) => entry.review);
  const reviewerParts = latestReviews.map((review) =>
    `${review.author.login} (${String(review.state).toLowerCase().replaceAll("_", " ")})`,
  );
  const changeRequesters = latestReviews
    .filter((review) => review.state === "CHANGES_REQUESTED")
    .map((review) => review.author.login);
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
  const reviewRecords = latestReviews.map((review) => ({
    author: review.author?.login ?? null,
    state: review.state ?? null,
    submittedAt: review.submittedAt ?? null,
    commitOid: review.commit?.oid ?? null,
  }));
  const reviewObservations = Object.fromEntries(
    [...latestActivityByAuthor.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([author, activity]) => [author, {
        lastReviewAt: activity.review.submittedAt ?? null,
        verdict: latestStateByAuthor.get(author)?.review.state ?? null,
      }]),
  );
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
    reviewRecords,
    reviewObservations,
    changeRequesters,
    requestedReviewers,
    headRefOid: data.headRefOid ?? null,
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

function notYetCheckedLabel(github, nowMs = Date.now()) {
  if (!github?.fetchedAtMs) return "checks unknown - not checked";
  const ageSeconds = secondsSince(github.fetchedAtMs, nowMs) ?? 0;
  const remainingSeconds = Math.max(0, WATCH_GITHUB_SECONDS - ageSeconds);
  return `not yet checked - next refresh ${formatDuration(remainingSeconds)}`;
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
  if (githubResult.readiness === "approved and ready to merge") {
    return githubResult.localChecksRequired
      ? { key: "unknown", source: "local" }
      : { key: "yellow", source: "forge" };
  }
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
  if (firstmatePr) {
    if (githubResult.readiness === "waiting on human review") {
      return "Wait for the requested reviewer, then record exact local-suite evidence before merge readiness is claimed.";
    }
    if (githubResult.readiness === "changes requested") {
      return "Address the current requested changes and record exact local-suite evidence before merge readiness is claimed.";
    }
    return "Record exact local-suite evidence; GitHub checks do not establish Firstmate CI readiness.";
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
async function fetchGithubThreadObservations(url, viewer, deadlineMs = null) {
  const match = url.match(/^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)\/?$/i);
  if (!match || !viewer) return null;
  try {
    const data = JSON.parse(await run("gh", [
      "api", "graphql",
      "-f", `query=${REVIEW_THREADS_QUERY}`,
      "-f", `owner=${match[1]}`,
      "-f", `name=${match[2]}`,
      "-F", `number=${match[3]}`,
    ], process.env, commandTimeout(deadlineMs), Number.isFinite(deadlineMs)));
    const nodes = data?.data?.repository?.pullRequest?.reviewThreads?.nodes;
    if (!Array.isArray(nodes)) return null;
    return Object.fromEntries(nodes.flatMap((thread) => {
      const firstComment = thread.comments?.nodes?.[0] ?? null;
      const actor = thread.isResolved ? thread.resolvedBy?.login : firstComment?.author?.login;
      if (!thread.id || !actor || actor.toLowerCase() === viewer.toLowerCase()) return [];
      return [[thread.id, {
        state: thread.isResolved ? "resolved" : "open",
        actor,
        openedAt: firstComment?.createdAt ?? null,
      }]];
    }));
  } catch (error) {
    if (error.timedOut) throw error;
    return null;
  }
}

async function fetchGithubStatuses(urls, viewer = null, deadlineMs = null) {
  const results = new Map();
  let error = null;
  for (const url of urls) {
    if (!/^https:\/\/github\.com\//.test(url)) {
      results.set(url, {
        ok: false,
        ci: "CI unknown (not a github.com PR)",
        readiness: "review readiness unknown (not a github.com PR)",
      });
      continue;
    }
    try {
      const text = await run("gh", [
        "pr",
        "view",
        url,
        "--json",
        "state,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,reviewRequests,headRefOid",
      ], process.env, commandTimeout(deadlineMs), Number.isFinite(deadlineMs));
      results.set(url, {
        ok: true,
        ...githubStatus(JSON.parse(text)),
        threadObservations: await fetchGithubThreadObservations(url, viewer, deadlineMs),
      });
    } catch (fetchError) {
      if (fetchError.timedOut) throw fetchError;
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

async function fetchForgeState(inputs, deadlineMs = null, mode = "full") {
  const reviewRequests = inputs.snapshot.backlog?.present === true || inputs.reviews.available
    ? await fetchReviewRequests(deadlineMs)
    : { available: false, fetchedAtMs: Date.now(), viewer: null, items: [], reason: "no fleet sources available" };
  if (mode === "review-requests") {
    return {
      reviewRequests,
      github: null,
      quota: {
        available: false,
        fetchedAtMs: null,
        providers: [],
        reason: "not checked for approvals section",
      },
    };
  }
  const urls = githubPrUrls(inputs, reviewRequests);
  return {
    reviewRequests,
    github: urls.length > 0 ? await fetchGithubStatuses(urls, reviewRequests.viewer, deadlineMs) : null,
    quota: await fetchQuota(deadlineMs),
  };
}

function fetchForgeStateAsync(inputs, mode) {
  return new Promise((resolvePromise, rejectPromise) => {
    const deadlineMs = Date.now() + FORGE_REFRESH_TIMEOUT_MS;
    const worker = new Worker(new URL(import.meta.url), {
      workerData: { operation: "fetch-forge-state", inputs, deadlineMs, mode },
    });
    let settled = false;
    const settle = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      callback();
    };
    const timeout = setTimeout(() => {
      settle(() => {
        worker.terminate().finally(() => {
          rejectPromise(new Error(`forge refresh timed out after ${FORGE_REFRESH_TIMEOUT_MS}ms`));
        });
      });
    }, FORGE_REFRESH_TIMEOUT_MS + 100);
    worker.once("message", (message) => {
      settle(() => {
        if (message.ok) resolvePromise(message.value);
        else if (message.timedOut) {
          worker.terminate().finally(() => {
            rejectPromise(new Error(`forge refresh timed out after ${FORGE_REFRESH_TIMEOUT_MS}ms`));
          });
        } else rejectPromise(new Error(message.error));
      });
    });
    worker.once("error", (error) => {
      settle(() => rejectPromise(error));
    });
    worker.once("exit", (code) => {
      settle(() => rejectPromise(new Error(`forge refresh worker exited ${code} without a result`)));
    });
  });
}

function runLocalWorker(operation) {
  return new Promise((resolvePromise, rejectPromise) => {
    const worker = new Worker(new URL(import.meta.url), {
      workerData: { operation },
    });
    let settled = false;
    worker.once("message", (message) => {
      settled = true;
      if (message.ok) resolvePromise(message.value);
      else rejectPromise(new Error(message.error));
    });
    worker.once("error", (error) => {
      settled = true;
      rejectPromise(error);
    });
    worker.once("exit", (code) => {
      if (!settled) rejectPromise(new Error(`${operation} worker exited ${code} without a result`));
    });
  });
}

async function collectEssentialLocalInputsAsync() {
  const [snapshot, reviews] = await Promise.all([
    runLocalWorker("collect-fleet-snapshot"),
    runLocalWorker("collect-review-relationships"),
  ]);
  return { snapshot, telemetryRows: null, telemetryPresent: existsSync(telemetryPath), reviews };
}

function buildModel({ snapshot, telemetryRows, telemetryPresent, reviews, github, reviewRequests, quota, forgeSkipped = false, peaceRecords = null }) {
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
  const building = [];
  const ours = [];
  const obligations = [];
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
        project: projectLabel(record.repo),
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
        identityVerb: "captain-hold",
        markerKey: looksAnswered ? "unknown" : "yellow",
        markerSource: "local",
        currentState: "captain hold open",
        blocker: cleanProse(record.hold_reason),
        recommendation: looksAnswered
          ? "Confirm the recorded answer so captain-hold-lifecycle can reconcile the still-open call."
          : aged
            ? "Re-evaluate this aged captain hold and answer it or explicitly keep it open."
            : "Answer the recorded captain hold.",
        why: looksAnswered
          ? "the open hold's own text carries an explicit answer marker; captain-hold-lifecycle still owns closure"
          : aged
            ? "captain hold remains open but is at least seven days old; captain-hold-lifecycle still owns closure"
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
      project: projectLabel(currentRecord?.repo || task.project),
      age: itemAge,
      live: task.endpoint?.exists === true,
      statusLog: task.paths?.status_log?.present ? task.paths.status_log.path : null,
      pr: task.pr?.url ? task.pr : null,
      report: task.paths?.report?.present ? task.paths.report.path : null,
      worktree: task.paths?.worktree?.path ?? null,
      currentState: state,
    };
    base.evidence = reportEvidence(base.report);
    const openDecisions = task.hints?.open_decisions || [];
    for (const decision of openDecisions.filter((entry) => entry.verb === "needs-decision")) {
      decisions.push({
        ...base,
        tag: "DECIDE",
        prose: cleanProse(decision.summary) || "decision summary absent",
        note: decision.key && decision.key !== "default" ? `[${decision.key}]` : null,
        attentionClass: "now",
        stableKey: decision.key ?? "default",
        identityVerb: "ask",
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
        identityVerb: "block",
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
        identityVerb: "block",
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
    if (
      task.kind !== "secondmate" &&
      currentRecord?.state === "in_flight" &&
      !registeredPr &&
      !stageMatch &&
      openDecisions.length === 0 &&
      state !== "blocked"
    ) {
      const markerKey = isStuckState(state)
        ? "red"
        : isProgressState(state)
          ? "green"
          : ["parked", "paused"].includes(state)
            ? "blue"
            : "unknown";
      building.push({
        ...base,
        tag: "BUILD",
        listLabel: `${base.name} | ${state}${detail ? ` | ${detail}` : ""}`,
        prose: detail || state,
        note: null,
        markerKey,
        markerSource: "local",
        blocker: isStuckState(state) ? detail || state : null,
        recommendation: isStuckState(state)
          ? `Resolve the recorded ${state} state: ${detail || "no detail recorded"}`
          : isProgressState(state)
            ? "No action for Pedro; this in-flight task is progressing."
            : ["parked", "paused"].includes(state)
              ? "No action for Pedro unless this paused task should resume."
              : "Reconcile the task's current state before choosing an action.",
        why: "structured in-flight task has no registered PR and no open decision",
      });
    }
    const githubResult = registeredPr ? github?.results?.get(task.pr.url) ?? null : null;
    const completedTerminalPr = completedIds.has(task.id) && registeredPr && githubResult?.terminal;
    if (
      task.kind !== "secondmate" &&
      ((!completedIds.has(task.id) && (registeredPr || stageMatch)) || completedTerminalPr)
    ) {
      const lastEvent = cleanProse(task.hints?.last_event_text).replaceAll(/https?:\/\/\S+/g, "").trim();
      const recorded = detail || lastEvent || "no status recorded";
      const registeredPrNumber = registeredPr ? task.pr.url.match(/\/pull\/(\d+)/)?.[1] ?? null : null;
      const prNumber = registeredPrNumber ?? stageMatch?.[1] ?? null;
      const firstmatePr = base.project === "firstmate" || (registeredPr && isFirstmatePr(task.pr.url));
      const effectiveGithubResult = firstmatePr && githubResult
        ? {
            ...githubResult,
            ci: "CI unknown",
            localChecksRequired: true,
          }
        : githubResult;
      const checkStatus = firstmatePr
          ? "local checks unknown"
        : !registeredPr
          ? "checks unknown (unregistered)"
          : githubResult
            ? checksLabel(githubResult.ci)
            : notYetCheckedLabel(github);
      const reviewStatus = !registeredPr
        ? "readiness unknown (unregistered)"
        : firstmatePr
          ? firstmateReadiness(githubResult)
          : readinessLabel(githubResult);
      const status = `${checkStatus} · ${reviewStatus}`;
      const datedChangeRequests = (githubResult?.reviewRecords ?? [])
        .filter((review) => review.state === "CHANGES_REQUESTED" && review.author)
        .map((review) => {
          const submitted = review.submittedAt ? review.submittedAt.slice(0, 10) : "date unknown";
          return `${review.author} on ${submitted}`;
        });
      const blocker = datedChangeRequests.length > 0
        ? `changes requested by ${datedChangeRequests.join(", ")}; remains blocking until approved or dismissed`
        : status;
      const marker = ourPrMarker(state, registeredPr, effectiveGithubResult);
      ours.push({
        ...base,
        tag: "OURS",
        prNumber,
        listLabel: `PR ${prNumber ?? "unknown"} | ${checkStatus} | ${registeredPr ? reviewStatus : "unregistered"}`,
        prose: status,
        note: registeredPr ? task.pr.url : null,
        markerKey: marker.key,
        markerSource: marker.source,
        blocker,
        review: registeredPr
          ? githubResult?.reviewSummary ?? "reviewers unknown (not checked yet)"
          : "reviewers unknown (PR not registered)",
        newnessSource: registeredPr
          ? { github: effectiveGithubResult, viewer: reviewRequests?.viewer ?? null }
          : null,
        hideWhenSeen: Boolean(completedTerminalPr),
        recommendation: ourPrRecommendation({
          markerKey: marker.key,
          registeredPr,
          githubResult: effectiveGithubResult,
          prNumber,
          firstmatePr,
        }),
        why: registeredPr
          ? completedTerminalPr
            ? "our PR was previously observed in review and now has terminal forge evidence"
            : "our PR recorded in task metadata and not yet landed in the backlog"
          : `current ship backlog record names PR ${prNumber ?? "unknown"}, but task metadata never registered it; last recorded: ${recorded}`,
      });
    }
  }

  const representedOurUrls = new Set(ours.map((item) => item.pr?.url).filter(Boolean));
  for (const entry of Object.values(readObservationStore()?.rows ?? {})) {
    const retained = entry?.row;
    if (
      retained?.kind !== "ours" ||
      !retained.url ||
      representedOurUrls.has(retained.url)
    ) continue;
    const githubResult = github?.results?.get(retained.url) ?? null;
    if (!githubResult?.terminal) continue;
    ours.push({
      tag: "OURS",
      name: retained.name,
      id: retained.taskId,
      project: retained.project,
      prNumber: retained.prNumber,
      listLabel: `PR ${retained.prNumber} | ${checksLabel(githubResult.ci)} | ${readinessLabel(githubResult)}`,
      prose: `${checksLabel(githubResult.ci)} · ${readinessLabel(githubResult)}`,
      note: retained.url,
      age: { seconds: null, label: "age unknown" },
      live: false,
      currentState: githubResult.forgeState,
      pr: { url: retained.url, source: "dashboard observation store" },
      markerKey: "green",
      markerSource: "forge",
      blocker: githubResult.readiness,
      review: githubResult.reviewSummary,
      newnessSource: { github: githubResult, viewer: reviewRequests?.viewer ?? null },
      hideWhenSeen: true,
      recommendation: "No action for Pedro; the PR is merged or closed.",
      evidence: { impact: null, manualScript: null, manualScriptOmittedFromHtml: false },
      why: "a previously observed PR reached terminal forge state after its task metadata was retired",
    });
  }

  for (const relationship of reviews.relationships) {
    const githubResult = relationship.link ? github?.results?.get(relationship.link) ?? null : null;
    const forgeState = relationship.link
      ? githubResult
        ? githubResult.ok
          ? `forge ${githubResult.forgeState}`
          : githubResult.readiness
        : "forge state unknown (not checked yet)"
      : "forge state unknown (PR link not recorded)";
    const marker = githubResult?.terminal
      ? { key: "green", source: "forge" }
      : !relationship.link || !githubResult?.ok
      ? { key: "unknown", source: "forge" }
      : relationship.holdReason || relationship.workflowState === "done"
        ? { key: "blue", source: "forge" }
        : relationship.workflowState === "in_flight"
          ? { key: "green", source: "forge" }
          : { key: "unknown", source: "forge" };
    const recommendation = githubResult?.terminal
      ? "No action for Pedro; the reviewed PR is merged or closed."
      : marker.key === "blue"
      ? "Wait for the author or external party; chase them only if the review stalls."
      : marker.key === "green"
        ? "No action for Pedro; the review round is progressing."
        : "Forge or workflow state is missing; a fresh status check must establish whether action is needed.";
    reviewing.push({
      tag: "THEIRS",
      name: relationship.name,
      listLabel: `${relationship.name} | ${relationship.status.replaceAll(" · ", " | ")}`,
      id: relationship.id,
      project: projectLabel(relationship.project),
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
      newnessSource: relationship.link
        ? { github: githubResult, viewer: reviewRequests?.viewer ?? null }
        : null,
      hideWhenSeen: Boolean(githubResult?.terminal),
      recommendation,
      evidence: { impact: null, manualScript: null, manualScriptOmittedFromHtml: false },
      why: relationship.linkSource === "verified_project_remote"
        ? "review records grouped by PR; link established from the recorded PR number and verified project GitHub remote"
        : "review records grouped by PR; completed rounds remain until terminal PR evidence exists",
    });
  }

  const relationshipByUrl = new Map(
    reviews.relationships.filter((relationship) => relationship.link).map((relationship) => [relationship.link, relationship]),
  );
  for (const request of reviewRequests?.items ?? []) {
    const githubResult = github?.results?.get(request.url) ?? null;
    const relationship = relationshipByUrl.get(request.url) ?? null;
    const recordedHeads = relationship?.heads ?? [];
    const viewerReview = reviewRequests?.viewer
      ? (githubResult?.reviewRecords ?? []).find((review) => review.author === reviewRequests.viewer) ?? null
      : null;
    const roundLabel = recordedHeads.length > 0
      ? `re-review ${recordedHeads.length + 1}`
      : viewerReview
        ? "re-review 2+"
        : "round unknown";
    const pushedSinceReview = recordedHeads.length > 0
      ? githubResult?.headRefOid
        ? !recordedHeads.includes(githubResult.headRefOid)
        : null
      : viewerReview?.commitOid && githubResult?.headRefOid
        ? viewerReview.commitOid !== githubResult.headRefOid
        : null;
    const manualEvidence = `${request.title ?? ""} ${relationship?.status ?? ""}`;
    const manualOutstanding = /manual validation[^.\n]*(?:required|outstanding|pending)/i.test(manualEvidence);
    const unansweredFindings = relationship?.holdReason
      ? /(?:waiting on (?:the )?(?:author|their|fix)|unanswered|findings?)/i.test(relationship.holdReason)
      : false;
    const waiting = request.requestedAt
      ? sinceAge(request.requestedAt)
      : { seconds: null, label: "waiting time unknown" };
    const stateParts = [
      waiting.seconds === null ? "waiting time unknown" : `waiting ${formatDuration(waiting.seconds)}`,
      roundLabel,
      pushedSinceReview === true ? "author pushed since review" : pushedSinceReview === false ? "head unchanged since review" : null,
      pushedSinceReview === null ? "head change unknown" : null,
      manualOutstanding ? "manual validation outstanding" : "manual validation unknown",
      unansweredFindings ? "findings recorded as unanswered" : "findings status unknown",
    ].filter(Boolean);
    obligations.push({
      tag: "REVIEW",
      name: `PR ${request.number}: ${cleanProse(request.title) || "title unknown"}`,
      listLabel: `PR ${request.number}${request.repository?.name ? ` [${request.repository.name}]` : ""} | ${stateParts.join(" | ")}`,
      id: `review-request-${request.repositoryName ?? "unknown"}-${request.number}`,
      stableKey: `${request.repositoryName ?? "unknown"}-${request.number}`,
      project: projectLabel(request.repository?.name ?? request.repositoryName?.split("/")[1]),
      prose: stateParts.join(" · "),
      note: request.url,
      age: waiting,
      live: false,
      raw: relationship?.raw ?? null,
      currentState: "review requested from Pedro",
      pr: { url: request.url, source: "GitHub requested-review search" },
      markerKey: "yellow",
      markerSource: "forge",
      blocker: request.requestedAt
        ? `Pedro has been a requested reviewer since ${request.requestedAt}`
        : "GitHub reports Pedro as requested reviewer; request date is unknown",
      review: stateParts.join(" · "),
      newnessSource: { reviewRequested: true },
      recommendation: manualOutstanding
        ? "Run the recorded manual validation, then submit the requested review."
        : "Review the current head and submit the requested review.",
      evidence: { impact: null, manualScript: null, manualScriptOmittedFromHtml: false },
      why: "GitHub currently reports the authenticated viewer as a requested reviewer",
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
  building.sort(oldestFirst);
  ours.sort(oldestFirst);
  obligations.sort(oldestFirst);
  reviewing.sort((left, right) => (left.age.seconds ?? Number.POSITIVE_INFINITY) - (right.age.seconds ?? Number.POSITIVE_INFINITY));

  for (const items of [decisions, building, ours, obligations, reviewing]) {
    items.sort((left, right) => MARKER_PRIORITY[left.markerKey] - MARKER_PRIORITY[right.markerKey]);
    for (const item of items) {
      item.marker = MARKERS[item.markerKey] ?? MARKERS.unknown;
    }
  }

  const localAttention = new Map();
  for (const item of [...decisions, ...ours, ...reviewing]) {
    if (
      item.markerSource === "local" &&
      ["yellow", "red"].includes(item.markerKey) &&
      !["aged", "answered"].includes(item.attentionClass)
    ) {
      const identity = `${item.project ?? ""}/${item.id ?? item.name}`;
      if (!localAttention.has(identity)) localAttention.set(identity, item);
    }
  }
  const sectionAttention = new Map(localAttention);
  for (const item of building) {
    if (
      item.markerSource === "local" &&
      ["yellow", "red"].includes(item.markerKey) &&
      (item.markerKey === "red" || item.explicitAsk)
    ) {
      const identity = `${item.project ?? ""}/${item.id ?? item.name}`;
      if (!sectionAttention.has(identity)) sectionAttention.set(identity, item);
    }
  }

  const model = {
    generated: snapshot.generated || "observation time absent",
    backlogPresent,
    telemetryPresent,
    reviews,
    github,
    reviewRequests,
    quota,
    forgeSkipped,
    peaceRecords,
    recap: {
      available: backlogPresent,
      needsPedro: [...localAttention.values()].filter((item) => item.markerKey === "yellow"),
      stuck: [...localAttention.values()].filter((item) => item.markerKey === "red"),
      obligations,
    },
    localRecap: {
      available: backlogPresent,
      needsPedro: [...sectionAttention.values()].filter((item) => item.markerKey === "yellow"),
      stuck: [...sectionAttention.values()].filter((item) => item.markerKey === "red"),
      obligations,
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
        key: "building",
        name: "BUILDING",
        htmlTitle: "Building",
        items: building,
        empty: "no in-flight task without a PR or open decision",
      },
      {
        key: "ours-in-review",
        name: "OUR PRS IN REVIEW",
        htmlTitle: "Our PRs in review",
        items: ours,
        empty: "no PR of ours recorded in review",
      },
      {
        key: "review-obligations",
        name: "REVIEWS WAITING ON PEDRO",
        htmlTitle: "Reviews waiting on Pedro",
        items: obligations,
        empty: reviewRequests?.available === false
          ? `review requests unknown - ${reviewRequests.reason}`
          : "nobody is waiting on Pedro for review",
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

  const rowByIdentity = new Map();
  for (const bucket of model.buckets) {
    for (const item of bucket.items) {
      item.bucketName = bucket.name;
      const decisionUsesKey = bucket.key === "decisions" && item.stableKey && item.stableKey !== item.id;
      const stablePart = bucket.key === "decisions"
        ? decisionUsesKey ? `${item.id}-${item.stableKey}-${item.identityVerb ?? "row"}` : item.id
        : bucket.key === "building"
          ? item.id
        : bucket.key === "ours-in-review"
          ? item.prNumber ?? "pr-unknown"
          : bucket.key === "review-obligations"
            ? item.stableKey
            : String(item.id).replace(/^pr-/, "");
      const prefix = bucket.key === "decisions"
        ? "d"
        : bucket.key === "building"
          ? "b"
        : bucket.key === "ours-in-review"
          ? "o"
          : bucket.key === "review-obligations"
            ? "v"
            : "r";
      const canonical = `${bucket.key}/${item.id}/${item.stableKey ?? ""}/${item.identityVerb ?? bucket.key}`;
      item.identity = readableRowId(
        prefix,
        stablePart,
        canonical,
        item.name,
        bucket.key === "ours-in-review",
      );
      const previous = rowByIdentity.get(item.identity);
      if (previous) {
        throw new Error(`duplicate cockpit row id ${item.identity}: ${previous.bucketName}/${previous.id} and ${item.bucketName}/${item.id}`);
      }
      rowByIdentity.set(item.identity, item);
    }
  }
  numberModelRows(model);
  return model;
}

function numberModelRows(model) {
  let rowNumber = 0;
  for (const bucket of model.buckets) {
    for (const item of bucket.items) {
      rowNumber += 1;
      item.number = rowNumber;
    }
  }
  model.totalRows = rowNumber;
}

function applySectionView(model, section) {
  const includedKeys = new Set(section === null ? DEFAULT_BUCKET_KEYS : SECTION_BUCKET_KEYS[section]);
  model.buckets = model.buckets.filter((bucket) => includedKeys.has(bucket.key));
  if (section !== null) {
    model.selectedSection = section;
    model.recap = model.localRecap;
  }
  numberModelRows(model);
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
  if (github?.loading) {
    if (!github.fetchedAtMs) return "checking GitHub…";
    const ageSeconds = secondsSince(github.fetchedAtMs, nowMs);
    return `checking GitHub… (last checked ${formatDuration(ageSeconds) ?? "?"} ago)`;
  }
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
  for (const item of [...recap.obligations, ...recap.stuck, ...recap.needsPedro]) {
    if (featured.length >= 2) break;
    if (!featured.includes(item)) featured.push(item);
  }
  return featured;
}

function recapNeedsPedroLabel(recap) {
  return `${recap.needsPedro.length} need Pedro`;
}

function visibleBucketItems(bucket, showAll) {
  if (showAll) return bucket.items;
  const candidates = bucket.items.filter((item) =>
    item.isNew || (
      ["yellow", "red"].includes(item.markerKey) &&
      !["aged", "answered"].includes(item.attentionClass)
    ),
  );
  return candidates
    .map((item, index) => ({ item, index }))
    .sort((left, right) => {
      const rank = ({ item }) => item.markerKey === "red" ? 0 : item.isNew ? 1 : 2;
      return rank(left) - rank(right) || left.index - right.index;
    })
    .slice(0, DEFAULT_BUCKET_LIMITS[bucket.key] ?? 0)
    .map(({ item }) => item);
}

function collapsedBucketLabel(bucket, count) {
  if (bucket.key === "decisions") return `${count} deferred decision${count === 1 ? "" : "s"}`;
  if (bucket.key === "building") return `${count} deferred task${count === 1 ? "" : "s"}`;
  if (bucket.key === "ours-in-review") return `${count} deferred PR${count === 1 ? "" : "s"}`;
  if (bucket.key === "review-obligations") return `${count} review request${count === 1 ? "" : "s"}`;
  if (bucket.key === "reviewing") return `${count} review relationship${count === 1 ? "" : "s"}`;
  return `${count} other item${count === 1 ? "" : "s"}`;
}

function bucketItemGroups(bucket, items) {
  if (bucket.key === "review-obligations") return [{ project: null, items }];
  const projectNames = [...new Set(items.map((item) => item.project || "project unknown"))];
  if (projectNames.length <= 1) return [{ project: null, items }];
  return projectNames.map((project) => ({
    project,
    items: items.filter((item) => (item.project || "project unknown") === project),
  }));
}

function renderPeaceTerminal(model) {
  return `PEACE\n${peaceRecordsLine(model.peaceRecords)}\n`;
}

function renderTerminal(model, width, useColor, showAll, nowMs = Date.now()) {
  if (model.selectedSection === "peace") {
    return renderPeaceTerminal(model);
  }
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
  lines.push("");
  if (model.selectedSection) {
    if (!model.recap.available) {
      lines.push(`${paint("bold", "ATTENTION NOW")} | local attention unknown - backlog source absent`);
    } else {
      const counts = [
        model.recap.needsPedro.length > 0 ? recapNeedsPedroLabel(model.recap) : null,
        model.recap.stuck.length > 0 ? `${model.recap.stuck.length} stuck` : null,
        model.recap.obligations.length > 0 ? `${model.recap.obligations.length} review${model.recap.obligations.length === 1 ? "" : "s"} waiting` : null,
      ].filter(Boolean);
      lines.push(`${paint("bold", "ATTENTION NOW")} | ${counts.length > 0 ? counts.join(" | ") : "nothing needs Pedro"}`);
    }
  } else if (!model.recap.available) {
    lines.push(paint("bold", "ATTENTION NOW"));
    lines.push(paint("dim", "  unknown - backlog source absent"));
  } else if (
    model.recap.needsPedro.length === 0 &&
    model.recap.stuck.length === 0 &&
    model.recap.obligations.length === 0
  ) {
    lines.push(`${paint("bold", "ATTENTION NOW")} | nothing needs Pedro`);
  } else {
    const counts = [
      model.recap.needsPedro.length > 0 ? recapNeedsPedroLabel(model.recap) : null,
      model.recap.stuck.length > 0 ? `${model.recap.stuck.length} stuck` : null,
      model.recap.obligations.length > 0 ? `${model.recap.obligations.length} review${model.recap.obligations.length === 1 ? "" : "s"} waiting` : null,
    ].filter(Boolean);
    if (!showAll) {
      lines.push(`${paint("bold", "ATTENTION NOW")} | ${counts.join(" | ")}`);
    } else {
      lines.push(paint("bold", "ATTENTION NOW"));
      lines.push(`  ${counts.join(" | ")}`);
      const featured = recapFeaturedItems(model.recap);
      for (const item of featured) {
        lines.push(`  ${paint(item.marker.color, item.marker.glyph)} ${clip(item.name, Math.max(1, width - 4))}`);
      }
      const hidden = model.recap.needsPedro.length + model.recap.stuck.length + model.recap.obligations.length - featured.length;
      if (hidden > 0) {
        lines.push(paint("dim", `  +${hidden} more below`));
      }
    }
  }

  for (const bucket of model.buckets) {
    lines.push("");
    const visibleItems = visibleBucketItems(bucket, showAll);
    const hiddenCount = bucket.items.length - visibleItems.length;
    const count = showAll
      ? ` (${bucket.items.length})`
      : hiddenCount > 0
        ? ` · ${collapsedBucketLabel(bucket, hiddenCount)} - --all shows`
        : bucket.key === "review-obligations"
          ? ` (${bucket.items.length})`
          : "";
    const label = `${bucket.name}${count} `;
    const header = `── ${label}${"─".repeat(Math.max(0, width - label.length - 3))}`;
    lines.push(paint("dim", clip(header, width)));
    if (bucket.items.length === 0) {
      lines.push(paint("dim", clip(`   ${bucket.empty}`, width)));
      continue;
    }
    const numberWidth = String(model.totalRows).length;
    for (const group of bucketItemGroups(bucket, visibleItems)) {
      if (group.project) lines.push(paint("dim", `   project ${group.project}`));
      for (const item of group.items) {
        const rowLabel = String(item.number).padStart(numberWidth);
        const prefix = `  ${rowLabel} `;
        const marker = paint(item.marker.color, item.marker.glyph);
        const stablePrefix = `${item.identity} `;
        const newnessSuffix = item.isNew ? " [NEW]" : "";
        const title = clip(
          item.listLabel ?? item.name,
          Math.max(1, width - prefix.length - stablePrefix.length - newnessSuffix.length - 2),
        );
        lines.push(
          `${paint("dim", `${prefix}${stablePrefix}`)}${marker} ${paint(item.attentionClass === "aged" ? "dim" : null, title)}${item.isNew ? paint("yellow", newnessSuffix) : ""}`,
        );
      }
    }
  }
  lines.push("");
  lines.push(paint("dim", clip("◆ needs Pedro | × stuck | ○ waiting elsewhere | ● progressing | ? unknown", width)));
  return `${lines.join("\n")}\n`;
}

function quotaDetailLines(quota, nowMs) {
  if (!quota?.available) {
    return [`quota: unknown${quota?.reason ? ` (${quota.reason})` : ""}`];
  }
  const lines = [];
  for (const provider of quota.providers) {
    const windows = Array.isArray(provider.windows) ? provider.windows : [];
    if (windows.length === 0) {
      lines.push(`quota: ${provider.label ?? provider.provider ?? "provider"} unknown`);
      continue;
    }
    for (const window of windows) {
      const remaining = Number.isFinite(window.percentRemaining) ? `${window.percentRemaining}% remaining` : "remaining unknown";
      const resetSeconds = secondsSince(nowMs, Date.parse(window.resetsAt || ""));
      const reset = resetSeconds === null ? "reset unknown" : `resets in ${formatDuration(resetSeconds)}`;
      lines.push(`quota: ${provider.label ?? provider.provider ?? "provider"} ${window.label ?? window.id ?? "window"} ${remaining}; ${reset}`);
    }
  }
  if (lines.length === 0) lines.push("quota: unknown (no provider windows reported)");
  const quotaObservedMs = Date.parse(quota.generatedAt || "");
  const dataAge = secondsSince(Number.isFinite(quotaObservedMs) ? quotaObservedMs : quota.fetchedAtMs, nowMs);
  lines.push(`quota data: ${dataAge !== null && dataAge < 3 ? "checked just now" : `checked ${formatDuration(dataAge) ?? "?"} ago`}`);
  return lines;
}

// Full single-item context: nothing truncated, every field sourced from data
// the cockpit already read. Task reports are the sole manual-script and impact
// source; absent named sections stay absent instead of being inferred.
function renderExpandedItem(item, model, options = {}) {
  const lines = [];
  lines.push(`#${item.number} | ${item.bucketName} | ${item.marker.glyph} ${item.marker.label}`);
  lines.push(item.name || "(unnamed)");
  lines.push("");
  lines.push(`row id: ${item.identity}`);
  lines.push(`new since last look: ${item.isNew ? "yes" : "no"}`);
  lines.push(`current state: ${item.currentState || "unknown"}`);
  lines.push(`age: ${item.age.label}`);
  lines.push("token usage: not measured");
  const observedDetailMs = Date.parse(model.generated || "");
  const quotaObservedMs = Date.parse(model.quota?.generatedAt || "");
  const establishedNowCandidates = [observedDetailMs, quotaObservedMs].filter(Number.isFinite);
  const detailNowMs = options.nowMs ?? (establishedNowCandidates.length > 0
    ? Math.max(...establishedNowCandidates)
    : Date.now());
  lines.push(...quotaDetailLines(model.quota, detailNowMs));
  if (item.prose) {
    lines.push(`detail: ${item.prose}`);
  }
  if (item.note) {
    lines.push(`note: ${item.note}`);
  }
  if (item.review) {
    lines.push(`review: ${item.review}`);
  }
  lines.push(`open review threads: ${item.pr?.url ? "unknown - not read from GitHub" : "not applicable"}`);
  lines.push(`blockers: ${item.blocker || "none established"}`);
  const recommendation = item.recommendation || "Evidence is incomplete; record current state before choosing an action.";
  lines.push(`context and recommendation: ${recommendation}`);
  lines.push(`verdict: ${recommendation}`);
  lines.push(`why here: ${item.why || "routing reason not recorded"}`);
  lines.push(`what this affects: ${item.evidence?.impact ? cleanProse(item.evidence.impact) : "not recorded in the task report"}`);
  const manualScript = item.evidence?.manualScript;
  if (options.forHtml && item.evidence?.manualScriptOmittedFromHtml) {
    lines.push(`manual test script: omitted from shareable HTML; use --show ${item.identity} in the interactive terminal detail.`);
  } else if (manualScript) {
    lines.push("manual test script (task report):");
    for (const line of manualScript.split(/\r?\n/)) lines.push(`  ${line}`);
  } else {
    lines.push("manual test script: no manual test script recorded in the task report");
  }
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
      .slice(-5)
      .map((event) => cleanProse(event));
    lines.push(`recent events (${item.statusLog}):`);
    const closed = events.filter((event) => /^done:/i.test(event));
    lines.push(`what we closed: ${closed.length > 0 ? closed.join(" | ") : "none established in recent events"}`);
    for (const event of events) {
      lines.push(`  ${event}`);
    }
  } else if (item.id && !item.raw) {
    lines.push("what we closed: none established in recent events");
    lines.push("recent events: no status log");
  } else {
    lines.push("what we closed: none established in recent events");
  }
  return `${lines.join("\n")}\n`;
}

// Every interactive and non-interactive expansion enters here so the later
// newness slice has one place to record a viewed row without touching renderers.
function expandRow(model, selection) {
  const items = model.buckets.flatMap((bucket) => bucket.items);
  let item;
  if (selection.identity) {
    const prefixRequested = selection.identity.endsWith("*");
    const requestedIdentity = prefixRequested ? selection.identity.slice(0, -1) : selection.identity;
    item = prefixRequested ? null : items.find((candidate) => candidate.identity === requestedIdentity);
    if (!item && prefixRequested) {
      const prefixMatches = items.filter((candidate) => candidate.identity.startsWith(requestedIdentity));
      if (prefixMatches.length > 1) {
        throw new Error(`--show ${selection.identity}: ambiguous row id prefix (${prefixMatches.map((candidate) => candidate.identity).join(", ")})`);
      }
      item = prefixMatches[0];
    }
  } else {
    item = items.find((candidate) => candidate.number === selection.number);
  }
  if (!item) {
    if (selection.number !== undefined) {
      throw new Error(`--show ${selection.number}: no such row (valid: 1..${model.totalRows})`);
    }
    throw new Error(`--show ${selection.identity}: no row has that id`);
  }
  const expanded = renderExpandedItem(item, model);
  markRowSeen(item);
  return expanded;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function htmlRow(item, model) {
  return `<li class="row${item.attentionClass === "aged" ? " row-aged" : ""}${item.isNew ? " row-new" : ""}">
    <details>
      <summary>
        <span class="row-number">${item.number}</span>
        <span class="row-id">${escapeHtml(item.identity)}</span>
        <span class="marker marker-${escapeHtml(item.markerKey)}" aria-label="${escapeHtml(item.marker.label)}">${escapeHtml(item.marker.glyph)}</span>
        <span class="row-title">${escapeHtml(item.listLabel ?? item.name ?? "detail absent")}</span>
        <span class="new-badge">${item.isNew ? "NEW" : ""}</span>
      </summary>
      <pre>${escapeHtml(renderExpandedItem(item, model, { forHtml: true }))}</pre>
    </details>
  </li>`;
}

function emptyState(message) {
  return `<li class="empty">${escapeHtml(message)}</li>`;
}

function htmlRows(bucket, items, model) {
  return bucketItemGroups(bucket, items).map((group) => [
    group.project ? `<li class="project-label">${escapeHtml(group.project)}</li>` : "",
    ...group.items.map((item) => htmlRow(item, model)),
  ].join("")).join("");
}

function sourceValue(label, value) {
  return `<div class="source"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderPeaceHtml(model) {
  const line = peaceRecordsLine(model.peaceRecords);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>PEACE</title>
</head>
<body>
  <h1>PEACE</h1>
  <p>${escapeHtml(line)}</p>
</body>
</html>
`;
}

function renderHtml(model) {
  if (model.selectedSection === "peace") {
    return renderPeaceHtml(model);
  }
  const featured = recapFeaturedItems(model.recap);
  const hiddenRecap = model.recap.needsPedro.length + model.recap.stuck.length + model.recap.obligations.length - featured.length;
  const recapCounts = [
    model.recap.needsPedro.length > 0 ? recapNeedsPedroLabel(model.recap) : null,
    model.recap.stuck.length > 0 ? `${model.recap.stuck.length} stuck` : null,
    model.recap.obligations.length > 0 ? `${model.recap.obligations.length} review${model.recap.obligations.length === 1 ? "" : "s"} waiting` : null,
  ].filter(Boolean);
  const recap = !model.recap.available
    ? '<p class="muted">Unknown - backlog source absent.</p>'
    : model.recap.needsPedro.length === 0 && model.recap.stuck.length === 0 && model.recap.obligations.length === 0
      ? "<p>Nothing needs Pedro.</p>"
      : model.selectedSection
        ? `<p><strong>${recapCounts.join(" | ")}</strong></p>`
        : [
            `<p><strong>${recapCounts.join(" | ")}</strong></p>`,
            ...featured.map((item) => `<p><strong class="marker marker-${escapeHtml(item.markerKey)}">${escapeHtml(item.marker.glyph)}</strong> ${escapeHtml(item.name)}</p>`),
            hiddenRecap > 0 ? `<p class="muted">+${hiddenRecap} more below</p>` : "",
          ].filter(Boolean).join("\n    ");
  const sections = model.buckets
    .map((bucket) => {
      const visible = visibleBucketItems(bucket, false);
      const hidden = bucket.items.filter((item) => !visible.includes(item));
      const deferred = hidden.length > 0
        ? `<details class="deferred"><summary>${escapeHtml(collapsedBucketLabel(bucket, hidden.length))}</summary><ol class="rows">${htmlRows(bucket, hidden, model)}</ol></details>`
        : "";
      return `<section id="${bucket.key}">
    <div class="section-head"><h2>${escapeHtml(bucket.htmlTitle)}</h2>${bucket.key === "review-obligations" ? `<p>${bucket.items.length} waiting</p>` : ""}</div>
    <ol class="rows">${htmlRows(bucket, visible, model) || (hidden.length === 0 ? emptyState(bucket.empty) : "")}</ol>
    ${deferred}
  </section>`;
    })
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
    .sources { margin-top:28px; color:var(--muted); font-size:.8rem; }
    .source { display:flex; gap:6px; }
    .source span { text-transform:uppercase; letter-spacing:.06em; }
    .recap { display:grid; gap:6px; margin:0 0 28px; }
    .recap h2 { color:var(--muted); }
    section { padding:22px 0; border-top:1px solid var(--line); }
    .section-head { display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:10px; color:var(--muted); }
    .section-head p { color:var(--muted); }
    .rows { display:grid; gap:2px; margin:0; padding:0; list-style:none; }
    .row { min-width:0; padding:5px 0; }
    .row details,.row summary { min-width:0; }
    .row summary { display:grid; grid-template-columns:3ch max-content 2ch minmax(0,1fr) max-content; gap:8px; align-items:baseline; cursor:pointer; list-style:none; }
    .row summary::-webkit-details-marker { display:none; }
    .row pre { overflow:auto; margin:10px 0 8px 3ch; padding:12px; border-left:1px solid var(--line); color:var(--muted); white-space:pre-wrap; overflow-wrap:anywhere; }
    .row-number,.row-id { color:var(--muted); font-variant-numeric:tabular-nums; }
    .row-number { text-align:right; }
    .row-title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .row-aged .row-title { color:var(--muted); }
    .new-badge { color:var(--yellow); font-size:.72rem; font-weight:800; letter-spacing:.08em; }
    .marker { font-weight:800; }
    .marker-yellow { color:var(--yellow); }
    .marker-red { color:var(--red); }
    .marker-blue { color:var(--blue); }
    .marker-green { color:var(--green); }
    .marker-unknown { color:var(--unknown); }
    .legend { display:flex; flex-wrap:wrap; gap:6px 16px; padding-top:20px; border-top:1px solid var(--line); color:var(--muted); font-size:.8rem; }
    .empty { color:var(--muted); }
    .project-label { margin:10px 0 2px; color:var(--muted); font-size:.72rem; letter-spacing:.08em; text-transform:uppercase; }
    .deferred { margin-top:8px; color:var(--muted); }
    .deferred > summary { cursor:pointer; }
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

  <div class="recap">
    <h2>Attention now</h2>
    ${recap}
  </div>

  ${sections}

  <details class="sources" aria-label="Source availability">
    <summary>Data sources and measurement limits</summary>
    ${sourceValue("Backlog source", model.backlogPresent ? "Present" : "Absent")}
    ${sourceValue("Model telemetry", model.telemetryPresent ? "Present" : "Absent")}
    ${sourceValue("Token spend", "Not measured")}
  </details>

  <p class="legend">
    ${Object.entries(MARKERS).map(([key, marker]) => `<span><strong class="marker marker-${key}">${escapeHtml(marker.glyph)}</strong> ${escapeHtml(marker.label)}</span>`).join("")}
  </p>
</main>
</body>
</html>
`;
}

async function collectLocalInputs() {
  const [snapshot, telemetry, reviews] = await Promise.all([
    collectFleetSnapshot(),
    collectTelemetry(),
    collectReviewRelationships(),
  ]);
  return { snapshot, ...telemetry, reviews };
}

async function collectFleetSnapshot() {
  const snapshotText = await run(resolve(scriptDirectory, "fm-fleet-snapshot.sh"), ["--local-json"]);
  let snapshot;
  try {
    snapshot = JSON.parse(snapshotText);
  } catch {
    throw new Error("fm-fleet-snapshot.sh returned malformed JSON");
  }
  return snapshot;
}

async function collectTelemetry() {
  const telemetryPresent = existsSync(telemetryPath);
  let telemetryRows = null;
  if (telemetryPresent) {
    const telemetryText = await run(resolve(scriptDirectory, "fm-model-telemetry.sh"), [
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
  return { telemetryRows, telemetryPresent };
}

function githubPrUrls(inputs, reviewRequests = null) {
  const records = Array.isArray(inputs.snapshot.backlog?.records) ? inputs.snapshot.backlog.records : [];
  const completed = new Set(
    records.filter((record) => record.structured && record.id && record.state === "done").map((record) => record.id),
  );
  const observationStore = readObservationStore();
  const retainedOurUrls = Object.values(observationStore?.rows ?? {})
    .map((entry) => entry?.row?.kind === "ours" ? entry.row.url : null)
    .filter(Boolean);
  const ours = (inputs.snapshot.tasks || [])
    .filter(
      (task) => {
        return task.kind !== "secondmate" && task.pr?.url && task.pr?.source === "meta" && (
          !completed.has(task.id) || retainedOurUrls.includes(task.pr.url)
        );
      },
    )
    .map((task) => task.pr.url);
  const required = [...new Set([...ours, ...retainedOurUrls])];
  const requiredSet = new Set(required);
  const theirs = (inputs.reviews.relationships || []).map((relationship) => relationship.link).filter(Boolean);
  const requested = (reviewRequests?.items || []).map((request) => request.url).filter(Boolean);
  const optional = [...new Set([...requested, ...theirs])]
    .filter((url) => !requiredSet.has(url))
    .slice(0, GITHUB_OPTIONAL_PR_LIMIT);
  return [...required, ...optional];
}

function writeAtomically(outputPath, contents, mode = 0o644) {
  mkdirSync(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.tmp-${process.pid}`;
  try {
    writeFileSync(temporaryPath, contents, { encoding: "utf8", mode });
    chmodSync(temporaryPath, mode);
    renameSync(temporaryPath, outputPath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function readObservationStore() {
  if (!existsSync(observationStorePath)) return null;
  let store;
  try {
    store = JSON.parse(readFileSync(observationStorePath, "utf8"));
  } catch {
    return null;
  }
  if (
    store?.version !== OBSERVATION_STORE_VERSION ||
    !store.rows ||
    typeof store.rows !== "object" ||
    Array.isArray(store.rows)
  ) {
    return null;
  }
  return store;
}

function writeObservationStore(store) {
  writeAtomically(observationStorePath, `${JSON.stringify(store, null, 2)}\n`, 0o600);
}

const observationLockSleepBuffer = new Int32Array(new SharedArrayBuffer(4));

function processStartIdentity(pid) {
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim() || null;
  } catch {
    return null;
  }
}

function observationLockOwnerIsDead() {
  try {
    const owner = JSON.parse(readFileSync(resolve(observationStoreLockPath, "owner.json"), "utf8"));
    if (!Number.isInteger(owner.pid) || owner.pid < 1 || typeof owner.processStart !== "string") return false;
    const currentStart = processStartIdentity(owner.pid);
    return currentStart === null || currentStart !== owner.processStart;
  } catch {
    return false;
  }
}

function recoverStaleObservationLock() {
  try {
    mkdirSync(observationStoreRecoveryLockPath, { mode: 0o700 });
  } catch (error) {
    if (error.code === "EEXIST") return false;
    throw error;
  }
  try {
    if (!existsSync(observationStoreLockPath) || !observationLockOwnerIsDead()) return false;
    rmSync(observationStoreLockPath, { recursive: true, force: true });
    return true;
  } finally {
    rmSync(observationStoreRecoveryLockPath, { recursive: true, force: true });
  }
}

function withObservationStoreLock(callback) {
  mkdirSync(stateDirectory, { recursive: true });
  const token = `${process.pid}:${Date.now()}:${Math.random()}`;
  const processStart = processStartIdentity(process.pid);
  if (!processStart) throw new Error("could not identify the fleet dashboard process for observation locking");
  const deadline = Date.now() + 5000;
  let acquired = false;
  while (!acquired) {
    try {
      mkdirSync(observationStoreLockPath, { mode: 0o700 });
      try {
        writeFileSync(
          resolve(observationStoreLockPath, "owner.json"),
          `${JSON.stringify({ pid: process.pid, processStart, token })}\n`,
          { encoding: "utf8", mode: 0o600 },
        );
        acquired = true;
      } catch (error) {
        rmSync(observationStoreLockPath, { recursive: true, force: true });
        throw error;
      }
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (recoverStaleObservationLock()) {
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error(`timed out waiting for fleet dashboard observation lock: ${observationStoreLockPath}`);
      }
      Atomics.wait(observationLockSleepBuffer, 0, 0, 10);
    }
  }
  try {
    return callback();
  } finally {
    try {
      const owner = JSON.parse(readFileSync(resolve(observationStoreLockPath, "owner.json"), "utf8"));
      if (owner.token === token) rmSync(observationStoreLockPath, { recursive: true, force: true });
    } catch {
      // A missing owner means this process no longer owns the lock; do not
      // remove a replacement acquired by another dashboard process.
    }
  }
}

function externalReviewObservations(source) {
  const viewer = source?.viewer;
  const observations = source?.github?.ok ? source.github.reviewObservations : null;
  if (!viewer || !observations || typeof observations !== "object") return null;
  return Object.fromEntries(
    Object.entries(observations)
      .filter(([author]) => author.toLowerCase() !== viewer.toLowerCase())
      .sort(([left], [right]) => left.localeCompare(right)),
  );
}

function watchedFingerprint(kind, value) {
  if (!value) return null;
  return `${kind}:${createHash("sha256").update(value).digest("hex")}`;
}

// This is the complete watched-field set. Age, active/running state, local
// heartbeats, presentation labels, and unattributable reviews cannot enter it.
function watchedValuesForItem(item) {
  const github = item.newnessSource?.github?.ok ? item.newnessSource.github : null;
  return {
    attention: item.bucketName === "DECISIONS"
      ? watchedFingerprint(item.identityVerb ?? "attention", cleanProse(item.blocker))
      : null,
    failure: isStuckState(item.currentState)
      ? watchedFingerprint(item.currentState, cleanProse(item.blocker || item.prose))
      : null,
    ci: github?.ci ?? null,
    forgeState: github?.forgeState ?? null,
    externalReviews: externalReviewObservations(item.newnessSource),
    externalThreads: github?.threadObservations ?? null,
    reviewRequest: item.bucketName === "REVIEWS WAITING ON PEDRO"
      ? item.newnessSource?.reviewRequested === true
      : null,
  };
}

function retainedRowForItem(item) {
  if (item.bucketName !== "OUR PRS IN REVIEW" || !item.pr?.url || !item.prNumber) return null;
  return {
    kind: "ours",
    taskId: item.id,
    name: item.name,
    project: item.project,
    prNumber: item.prNumber,
    url: item.pr.url,
  };
}

function observationRevisionForItem(item, model) {
  return {
    local: Date.parse(model.generated || "") || null,
    forge: item.newnessSource?.github ? model.github?.fetchedAtMs ?? null : null,
  };
}

function revisionCovers(candidate, required) {
  if (!required) return true;
  return ["local", "forge"].every((key) =>
    required[key] === null || (
      Number.isFinite(candidate?.[key]) && candidate[key] >= required[key]
    ),
  );
}

function hasExternalThreadChange(current, previous) {
  if (!current || !previous || typeof previous !== "object") return false;
  return Object.entries(current).some(([threadId, observation]) => {
    const prior = previous[threadId];
    if (!prior) return true;
    // GitHub identifies who resolved a thread, but not who reopened one.
    // A resolved -> open transition is therefore unattributable and quiet.
    return prior.state === "open" && observation.state === "resolved";
  });
}

function hasExternalReviewChange(current, previous) {
  if (!current || !previous || typeof previous !== "object") return false;
  return Object.entries(current).some(([author, observation]) => {
    const currentAt = Date.parse(observation?.lastReviewAt ?? "");
    if (!Number.isFinite(currentAt)) return false;
    const previousObservation = previous[author];
    if (!previousObservation) return true;
    const previousAt = Date.parse(previousObservation.lastReviewAt ?? "");
    return Number.isFinite(previousAt) && currentAt > previousAt;
  });
}

function hasMeaningfulNewness(current, previous) {
  if (!previous) {
    return Boolean(current.attention || current.failure || current.reviewRequest);
  }
  if (current.attention && current.attention !== previous.attention) return true;
  if (current.failure && current.failure !== previous.failure) return true;
  if (current.reviewRequest && current.reviewRequest !== previous.reviewRequest) return true;
  if (
    ["CI red", "CI green"].includes(current.ci) &&
    ["CI red", "CI green", "CI running", "CI none reported"].includes(previous.ci) &&
    current.ci !== previous.ci
  ) return true;
  if (
    ["merged", "closed"].includes(current.forgeState) &&
    current.forgeState !== previous.forgeState
  ) return true;
  return hasExternalReviewChange(current.externalReviews, previous.externalReviews) ||
    hasExternalThreadChange(current.externalThreads, previous.externalThreads);
}

function previewNewness(model) {
  const store = readObservationStore();
  for (const item of model.buckets.flatMap((bucket) => bucket.items)) {
    const entry = store?.rows?.[item.identity] ?? null;
    item.isNew = entry?.pending === true;
    item.observationSnapshot = {
      watched: watchedValuesForItem(item),
      pending: item.isNew,
      revision: observationRevisionForItem(item, model),
    };
  }
  numberModelRows(model);
}

function applyNewness(model) {
  withObservationStoreLock(() => {
    const items = model.buckets.flatMap((bucket) => bucket.items);
    const existingStore = readObservationStore();
    const firstRun = existingStore === null;
    const store = existingStore ?? { version: OBSERVATION_STORE_VERSION, rows: {} };
    let storeChanged = firstRun;
    for (const item of items) {
      const watched = watchedValuesForItem(item);
      const revision = observationRevisionForItem(item, model);
      const entry = store.rows[item.identity] ?? null;
      if (model.forgeSkipped && item.bucketName === "REVIEWING") {
        item.isNew = entry?.pending === true;
        item.observationSnapshot = { watched, pending: item.isNew, revision };
        continue;
      }
      const newlyMeaningful = firstRun ? false : hasMeaningfulNewness(watched, entry?.watched ?? null);
      const pending = entry?.pending === true || newlyMeaningful;
      item.isNew = pending;
      item.observationSnapshot = { watched, pending, revision };
      if (!entry) {
        if (!item.hideWhenSeen || pending) {
          store.rows[item.identity] = {
            watched,
            pending,
            pendingRevision: pending ? revision : null,
            row: retainedRowForItem(item),
          };
          storeChanged = true;
        }
      } else if (pending !== (entry.pending === true)) {
        entry.pending = pending;
        entry.pendingRevision = pending ? revision : null;
        storeChanged = true;
      }
      const retainedRow = retainedRowForItem(item);
      if (JSON.stringify(entry?.row ?? null) !== JSON.stringify(retainedRow)) {
        if (store.rows[item.identity]) store.rows[item.identity].row = retainedRow;
        storeChanged = true;
      }
      if (item.hideWhenSeen && !pending && store.rows[item.identity]) {
        delete store.rows[item.identity];
        storeChanged = true;
      }
    }
    const currentIdentities = new Set(items.map((item) => item.identity));
    for (const identity of Object.keys(store.rows)) {
      const decisionRetired = identity.startsWith("d:") && model.backlogPresent;
      const requestRetired = identity.startsWith("v:") && model.reviewRequests?.available === true;
      if (!currentIdentities.has(identity) && (decisionRetired || requestRetired)) {
        delete store.rows[identity];
        storeChanged = true;
      }
    }
    for (const bucket of model.buckets) {
      bucket.items = bucket.items.filter((item) => !item.hideWhenSeen || item.isNew);
    }
    numberModelRows(model);
    if (storeChanged) writeObservationStore(store);
  });
}

function markRowSeen(item) {
  let acknowledged = false;
  withObservationStoreLock(() => {
    const store = readObservationStore() ?? { version: OBSERVATION_STORE_VERSION, rows: {} };
    const watched = watchedValuesForItem(item);
    const current = store.rows[item.identity] ?? null;
    const observed = item.observationSnapshot;
    if (
      observed &&
      (current?.pending === true) === observed.pending &&
      revisionCovers(observed.revision, current?.pendingRevision ?? null) &&
      (JSON.stringify(current?.watched ?? null) !== JSON.stringify(watched) || current?.pending === true)
    ) {
      store.rows[item.identity] = {
        ...current,
        watched,
        pending: false,
        pendingRevision: null,
        row: current?.row ?? retainedRowForItem(item),
      };
      writeObservationStore(store);
      acknowledged = true;
    }
  });
  if (acknowledged) item.isNew = false;
  return acknowledged;
}

function terminalFrame(body) {
  const erasedLines = body.split("\n").map((line) => `${line}\u001b[K`).join("\n");
  return `\u001b[?2026h\u001b[H${erasedLines}\u001b[J\u001b[?2026l`;
}

// Internal loop rather than external watch(1) because the GitHub cache must
// survive between redraws; two cadences so forge polling stays slow while
// local file-derived state stays fresh. The alternate screen buffer keeps
// scrollback intact and home-then-erase redraws avoid flicker.
function watchLoop(width, useColor, showAll, section) {
  if (!process.stdout.isTTY || !process.stdin.isTTY) {
    throw new Error("--watch requires a terminal with interactive input");
  }
  emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  const peaceDegradations = new Set();
  process.stdout.write("\u001b[?1049h\u001b[?25l");
  process.on("exit", () => {
    if (process.stdin.isRaw) process.stdin.setRawMode(false);
    process.stdout.write("\u001b[?25h\u001b[?1049l");
    for (const reason of peaceDegradations) {
      process.stderr.write(peaceDegradationLine(reason));
    }
  });
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));

  const forgeMode = sectionForgeMode(section);
  const forgeEnabled = forgeMode !== "none";
  const initialForge = forgeEnabled ? { github: null, reviewRequests: null, quota: null } : skippedForgeState();
  let { github, reviewRequests, quota } = initialForge;
  let model = null;
  let selectedIdentity = null;
  let selectedAcknowledged = false;
  let input = "";
  let inputError = null;
  let refreshTimer = null;
  let inputs = null;
  let localRefreshInFlight = false;
  let localRefreshError = null;
  let forgeRefreshInFlight = false;
  let lastForgeRefreshAtMs = null;
  let firstForgeRefresh = forgeEnabled;
  let lastPeaceRefreshAtMs = null;
  let peaceRecords = null;

  const draw = () => {
    const frameWidth = width ?? process.stdout.columns ?? 80;
    if (!model) {
      const detail = localRefreshError
        ? `local fleet state unavailable: ${localRefreshError}`
        : "loading local fleet state…";
      const prompt = input
        ? `select row: ${input}_ while local state loads | q: exit`
        : "q: exit";
      const body = `FIRSTMATE FLEET\n\n${detail}\n\n${prompt}\n`;
      process.stdout.write(terminalFrame(body));
      return;
    }
    let body;
    if (selectedIdentity !== null) {
      if (selectedAcknowledged) {
        const selected = model.buckets
          .flatMap((bucket) => bucket.items)
          .find((item) => item.identity === selectedIdentity);
        body = renderExpandedItem(selected, model);
      } else {
        body = expandRow(model, { identity: selectedIdentity });
        selectedAcknowledged = true;
      }
      body += "\nb or escape: back | q: exit\n";
    } else {
      body = renderTerminal(model, frameWidth, useColor, showAll, Date.now());
      const prompt = inputError ?? (input
        ? `select row: ${input}_ then Enter`
        : localRefreshInFlight
          ? "refreshing local fleet state… | q: exit"
          : "select: type row number + Enter | q: exit");
      body += `${useColor ? ANSI.dim : ""}${clip(prompt, Math.min(frameWidth, 80))}${useColor ? ANSI.reset : ""}\n`;
    }
    process.stdout.write(terminalFrame(body));
  };

  const rebuildModel = (previewOnly = false) => {
    model = buildModel({ ...inputs, github, reviewRequests, quota, forgeSkipped: forgeMode !== "full" });
    if (previewOnly) previewNewness(model);
    else applyNewness(model);
    applySectionView(model, section);
    if (
      selectedIdentity !== null &&
      !model.buckets.flatMap((bucket) => bucket.items).some((item) => item.identity === selectedIdentity)
    ) {
      selectedIdentity = null;
      selectedAcknowledged = false;
    }
    draw();
  };

  const refreshForge = () => {
    forgeRefreshInFlight = true;
    const githubWillBeChecked = inputs.snapshot.backlog?.present === true ||
      inputs.reviews.available ||
      githubPrUrls(inputs).some((url) => /^https:\/\/github\.com\//.test(url));
    github = forgeMode === "full" && githubWillBeChecked
      ? github
        ? { ...github, loading: true }
        : { loading: true, fetchedAtMs: null, results: new Map(), error: null }
      : null;
    if (reviewRequests === null) {
      reviewRequests = githubWillBeChecked
        ? {
            available: false,
            loading: true,
            fetchedAtMs: null,
            viewer: null,
            items: [],
            reason: "checking GitHub…",
          }
        : {
            available: false,
            fetchedAtMs: Date.now(),
            viewer: null,
            items: [],
            reason: "no fleet sources available",
          };
    }
    if (forgeMode === "full" && quota === null) {
      quota = { available: false, loading: true, fetchedAtMs: null, providers: [], reason: "checking quota…" };
    } else if (forgeMode !== "full") {
      quota = {
        available: false,
        fetchedAtMs: null,
        providers: [],
        reason: "not checked for approvals section",
      };
    }
    rebuildModel(firstForgeRefresh);
    fetchForgeStateAsync(inputs, forgeMode).then((forge) => {
      ({ github, reviewRequests, quota } = forge);
      forgeRefreshInFlight = false;
      lastForgeRefreshAtMs = Date.now();
      rebuildModel(false);
      firstForgeRefresh = false;
    }).catch((error) => {
      const fetchedAtMs = Date.now();
      github = forgeMode === "full"
        ? { loading: false, fetchedAtMs, results: new Map(), error: error.message }
        : null;
      reviewRequests = {
        available: false,
        fetchedAtMs,
        viewer: null,
        items: [],
        reason: error.message,
      };
      quota = forgeMode === "full"
        ? { available: false, fetchedAtMs, providers: [], reason: error.message }
        : { available: false, fetchedAtMs: null, providers: [], reason: "not checked for approvals section" };
      forgeRefreshInFlight = false;
      lastForgeRefreshAtMs = fetchedAtMs;
      rebuildModel(false);
      firstForgeRefresh = false;
    });
  };

  const frame = () => {
    if (localRefreshInFlight) return;
    localRefreshInFlight = true;
    localRefreshError = null;
    draw();
    const telemetryPromise = runLocalWorker("collect-telemetry").catch(() => ({
      telemetryRows: null,
      telemetryPresent: existsSync(telemetryPath),
    }));
    collectEssentialLocalInputsAsync().then(async (collected) => {
      if (section === "peace") {
        const peaceIsDue = lastPeaceRefreshAtMs === null ||
          secondsSince(lastPeaceRefreshAtMs, Date.now()) >= WATCH_GITHUB_SECONDS;
        if (peaceIsDue) {
          peaceRecords = await collectPeaceRecords();
          lastPeaceRefreshAtMs = Date.now();
          if (peaceRecords.strandedReason) peaceDegradations.add(peaceRecords.strandedReason);
        }
        collected.peaceRecords = peaceRecords;
      }
      inputs = collected;
      const forgeIsDue = lastForgeRefreshAtMs === null ||
        secondsSince(lastForgeRefreshAtMs, Date.now()) >= WATCH_GITHUB_SECONDS;
      if (forgeEnabled && forgeIsDue && !forgeRefreshInFlight) refreshForge();
      else rebuildModel(firstForgeRefresh);
      return telemetryPromise;
    }).then((telemetry) => {
      inputs = { ...inputs, ...telemetry };
      rebuildModel(firstForgeRefresh);
    }).catch((error) => {
      localRefreshError = error.message;
      draw();
    }).finally(() => {
      localRefreshInFlight = false;
      refreshTimer = setTimeout(frame, WATCH_LOCAL_SECONDS * 1000);
    });
  };

  process.stdin.on("keypress", (_character, key) => {
    if ((key?.ctrl && key.name === "c") || key?.name === "q") process.exit(0);
    if (selectedIdentity !== null) {
      if (key?.name === "b" || key?.name === "escape") {
        selectedIdentity = null;
        selectedAcknowledged = false;
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
        selectedAcknowledged = false;
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
  draw();
  frame();
}

if (!isMainThread && workerData?.operation === "fetch-forge-state") {
  try {
    parentPort.postMessage({
      ok: true,
      value: await fetchForgeState(workerData.inputs, workerData.deadlineMs, workerData.mode),
    });
  } catch (error) {
    parentPort.postMessage({
      ok: false,
      error: error.message,
      timedOut: error.timedOut === true || Date.now() >= workerData.deadlineMs,
    });
  }
} else if (!isMainThread && workerData?.operation === "collect-fleet-snapshot") {
  try {
    parentPort.postMessage({ ok: true, value: await collectFleetSnapshot() });
  } catch (error) {
    parentPort.postMessage({ ok: false, error: error.message });
  }
} else if (!isMainThread && workerData?.operation === "collect-telemetry") {
  try {
    parentPort.postMessage({ ok: true, value: await collectTelemetry() });
  } catch (error) {
    parentPort.postMessage({ ok: false, error: error.message });
  }
} else if (!isMainThread && workerData?.operation === "collect-review-relationships") {
  try {
    parentPort.postMessage({ ok: true, value: await collectReviewRelationships() });
  } catch (error) {
    parentPort.postMessage({ ok: false, error: error.message });
  }
} else if (isMainThread) {
  try {
    const { outputPath, width, showAll, section, showRow, watch } = parseArguments(process.argv.slice(2));
    if (outputPath !== null) {
      assertSafeOutput(outputPath);
    }
    if (watch) {
      watchLoop(width, process.env.NO_COLOR ? false : true, showAll, section);
    } else {
      const inputs = await collectLocalInputs();
      if (section === "peace") {
        inputs.peaceRecords = await collectPeaceRecords();
        if (inputs.peaceRecords.ghostReason) {
          process.stderr.write(peaceOneShotDegradationLine("ghost", inputs.peaceRecords.ghostReason));
        }
        if (inputs.peaceRecords.strandedReason) {
          process.stderr.write(peaceOneShotDegradationLine("stranded", inputs.peaceRecords.strandedReason));
        }
      }
      const forgeMode = sectionForgeMode(section);
      const forge = forgeMode === "none" ? skippedForgeState() : await fetchForgeState(inputs, null, forgeMode);
      const model = buildModel({ ...inputs, ...forge, forgeSkipped: forgeMode !== "full" });
      applyNewness(model);
      applySectionView(model, section);
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
}
