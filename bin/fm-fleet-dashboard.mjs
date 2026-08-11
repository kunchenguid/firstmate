#!/usr/bin/env node
// Render the Firstmate fleet cockpit from live state.
//
// Sources stay read-only: fm-fleet-snapshot.sh (built on fm-crew-state.sh and
// fm-classify-lib.sh) owns meta/status/backlog classification, and
// fm-model-telemetry.sh owns its attempt sheet.
//
// One view model, two renderers:
//   default            ANSI terminal cockpit on stdout (no args, no server)
//   --output <path>    self-contained HTML page written to <path>
// The HTML output may never be written under data/, state/, or config/.
//
// The four buckets are Pedro's own daily read, mutually exclusive, in the
// order he resolves them: Needs Pedro, Underway, Unhealthy, Queued.

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

function usage(stream = process.stdout) {
  stream.write(`usage: fm-fleet-dashboard.mjs [--width <columns>] [--all] [--show <row>] [--output <path>]

Render the fleet cockpit from live read-only state.
Default output is an ANSI terminal view on stdout (pairs with watch/tmux).
--width <columns>  terminal width override (default: tty width, else 80)
--all              list every item; default caps each section to fit ~40 rows
--show <row>       print one row's full context by its rendered row number
--output <path>    write the self-contained HTML page to <path> instead
The HTML output may never be written under data/, state/, or config/.
`);
}

function parseArguments(argumentsList) {
  let outputPath = null;
  let width = null;
  let showAll = false;
  let showRow = null;
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
  return { outputPath, width, showAll, showRow };
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

function run(command, argumentsList) {
  try {
    return execFileSync(command, argumentsList, {
      encoding: "utf8",
      env: process.env,
      maxBuffer: 16 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
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

function buildModel({ snapshot, telemetryRows, telemetryPresent }) {
  const observedMilliseconds = Date.parse(snapshot.generated || "");
  const backlogPresent = snapshot.backlog?.present === true;
  const records = Array.isArray(snapshot.backlog?.records) ? snapshot.backlog.records : [];
  const tasks = Array.isArray(snapshot.tasks) ? snapshot.tasks : [];

  const needsPedro = [];
  const underway = [];
  const unhealthy = [];
  const queued = [];
  const unreadable = [];

  const sinceAge = (record) => age(secondsSince(Date.parse(record.since || ""), observedMilliseconds));
  const waitsOn = (record) =>
    record.unresolved_blocker_ids?.length ? `waits on ${record.unresolved_blocker_ids.join(", ")}` : null;
  const titleById = new Map(
    records
      .filter((record) => record.structured && record.id && record.title)
      .map((record) => [record.id, cleanProse(record.title)]),
  );
  const completedById = new Map(
    records
      .filter((record) => record.structured && record.id && record.state === "done")
      .map((record) => [record.id, record]),
  );
  const heldById = new Map(
    records
      .filter((record) => record.structured && record.id && record.state !== "done" && record.hold_reason)
      .map((record) => [record.id, record]),
  );
  const isActionableCaptainHold = (record) =>
    record.hold_kind === "captain" && record.hold_reason && !record.unresolved_blocker_ids?.length;

  for (const record of records) {
    if (!record.structured) {
      if (record.state === "queued" || record.state === "in_flight") {
        queued.push({
          tag: "NOTE",
          name: cleanProse(record.raw),
          project: null,
          prose: null,
          note: "unstructured backlog line",
          age: age(null),
          raw: record.raw,
          why: "free-form backlog line the structured parser cannot classify",
        });
      }
      continue;
    }
    if (record.state === "done") {
      continue;
    }
    const recordName = cleanProse(record.title) || record.id;
    const isCaptainHold = record.hold_kind === "captain" && record.hold_reason;
    if (isActionableCaptainHold(record)) {
      needsPedro.push({
        tag: "HOLD",
        name: recordName,
        id: record.id,
        project: record.repo,
        prose: cleanProse(record.hold_reason),
        note: null,
        age: sinceAge(record),
        live: false,
        raw: record.raw,
        why: "captain hold with no unresolved blockers - only Pedro can clear it",
      });
      continue;
    }
    if (record.state === "queued" || isCaptainHold) {
      queued.push({
        tag: isCaptainHold ? "HOLD" : "QUEUED",
        name: recordName,
        id: record.id,
        project: record.repo,
        prose: null,
        note: waitsOn(record),
        age: sinceAge(record),
        raw: record.raw,
        why: isCaptainHold
          ? "captain hold still waiting on unresolved blockers"
          : "queued in backlog behind its dependencies or time gate",
      });
    }
  }

  for (const orphanId of snapshot.main_inventory?.orphan_in_flight || []) {
    const record = records.find((candidate) => candidate.id === orphanId);
    unhealthy.push({
      tag: "ORPHAN",
      name: record?.title ? cleanProse(record.title) : orphanId,
      id: orphanId,
      project: record?.repo ?? null,
      prose: "recorded in flight but no worker record exists",
      note: null,
      age: record ? sinceAge(record) : age(null),
      raw: record?.raw ?? null,
      why: "backlog records it in flight but no worker record exists for it",
    });
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
      note: telemetry?.tuple ?? null,
      live: task.endpoint?.exists === true,
      statusLog: task.paths?.status_log?.present ? task.paths.status_log.path : null,
      pr: task.pr?.url ? task.pr : null,
      report: task.paths?.report?.present ? task.paths.report.path : null,
      worktree: task.paths?.worktree?.path ?? null,
    };
    const openDecisions = task.hints?.open_decisions || [];
    const decisions = openDecisions.filter((decision) => decision.verb === "needs-decision");
    const blockers = openDecisions.filter((decision) => decision.verb === "blocked");

    if (decisions.length || blockers.length) {
      for (const decision of decisions) {
        needsPedro.push({
          ...base,
          tag: "DECIDE",
          prose: cleanProse(decision.summary) || "decision summary absent",
          note: decision.key && decision.key !== "default" ? `[${decision.key}]` : null,
          why: "open needs-decision in the keyed decision fold, not yet resolved",
        });
      }
      for (const blocker of blockers) {
        needsPedro.push({
          ...base,
          tag: "BLOCKED",
          prose: cleanProse(blocker.summary) || "blocker summary absent",
          note: blocker.key && blocker.key !== "default" ? `[${blocker.key}]` : null,
          why: "open blocked event in the keyed decision fold, not yet resolved",
        });
      }
      continue;
    }
    // A secondmate is a persistent agent, not a work item: its multiplexed
    // status log must never mint work rows. Its keyed open decisions already
    // surfaced above; beyond that only a dead agent is worth a line.
    if (task.kind === "secondmate") {
      if (task.endpoint?.agent_alive === "dead") {
        unhealthy.push({
          ...base,
          tag: "DEAD",
          prose: "secondmate agent is dead",
          note: null,
          why: "secondmate agent reads dead on a live endpoint check",
        });
      }
      continue;
    }
    // The reconciled current state from fm-crew-state is authoritative for
    // routing. Raw signals never override it: a gone endpoint is unhealthy
    // only when the state claims a live worker, and a reported PR is an ask
    // only while the fleet's own backlog does not already record it landed.
    if (state === "blocked") {
      needsPedro.push({
        ...base,
        tag: "BLOCKED",
        prose: detail || "blocked, no detail reported",
        note: null,
        why: "reconciled current state is blocked",
      });
      continue;
    }
    if (state === "paused") {
      queued.push({
        ...base,
        tag: "PAUSED",
        prose: null,
        note: detail || "declared external wait",
        why: "reconciled current state is a declared bounded external wait",
      });
      continue;
    }
    if (state === "done") {
      // Only the pr= recorded in task metadata is current state; a URL parsed
      // out of status prose is history. Whether the PR is still open cannot
      // be decided locally, so the ask never claims readiness.
      if (task.pr?.url && task.pr?.source === "meta" && !completedById.get(task.id)) {
        needsPedro.push({
          ...base,
          tag: "REVIEW",
          prose: `PR (unverified): ${task.pr.url}`,
          note: null,
          why: "task done with a PR recorded in its metadata and no backlog completion; PR openness is not locally verifiable",
        });
      }
      // Finished work belongs to no bucket; landing and cleanup are
      // firstmate's own pipeline, not fleet attention.
      continue;
    }
    // A worker whose current state is unreadable is not automatically sick:
    // reconcile against the durable records first. A backlog completion means
    // it landed; a hold means it is deliberately preserved; a declared pause
    // is a bounded external wait. Only a worker no record accounts for is
    // unhealthy.
    if (state === "unknown") {
      if (completedById.get(task.id)) {
        continue;
      }
      const held = heldById.get(task.id);
      if (held) {
        if (isActionableCaptainHold(held)) {
          continue;
        }
        queued.push({
          ...base,
          tag: "HOLD",
          prose: null,
          note: `held: ${cleanProse(held.hold_reason)}`,
          age: sinceAge(held),
          why: "state unreadable, but a backlog hold records it deliberately preserved",
        });
        continue;
      }
      const lastEvent = task.paths?.status_log?.last_event;
      if (lastEvent?.state === "paused") {
        queued.push({
          ...base,
          tag: "PAUSED",
          prose: null,
          note: `declared wait, worker gone: ${cleanProse(lastEvent.note) || "no reason recorded"}`,
          why: "worker gone, but its last event declares a bounded external wait",
        });
        continue;
      }
      if (lastEvent?.state === "failed") {
        unhealthy.push({
          ...base,
          tag: "FAILED",
          prose: cleanProse(lastEvent.note) || "reported failed",
          note: "current state unreadable",
          why: "last recorded event is a failure and no record supersedes it; current state unreadable",
        });
        continue;
      }
      // No record evidences this task as bad; the reader simply cannot read
      // its current state. That is a fact about the reader, not the worker.
      unreadable.push({
        ...base,
        tag: "?",
        prose: null,
        note: detail || "state unreadable",
        why: "current state cannot be read and nothing evidences it as bad",
      });
      continue;
    }
    if (state === "failed" || task.endpoint?.exists === false || task.endpoint?.agent_alive === "dead") {
      const reason = state === "failed" ? detail || "run failed" : "worker gone while its state claims live work";
      const lastEvent = cleanProse(task.hints?.last_event_text);
      unhealthy.push({
        ...base,
        tag: state === "failed" ? "FAILED" : "MISSING",
        prose: reason,
        note: lastEvent && !reason.includes(lastEvent) ? `last event: ${lastEvent}` : base.note,
      });
      continue;
    }
    underway.push({
      ...base,
      tag: state === "parked" ? "AT GATE" : "WORKING",
      prose: detail || "no detail reported",
    });
  }

  const oldestFirst = (left, right) => (right.age.seconds ?? -1) - (left.age.seconds ?? -1);
  // The printed selection rule: a live worker waiting on an answer is unblocked
  // the moment Pedro replies, so it outranks a PR review, which outranks a
  // standing hold; everything else last, oldest first within each group.
  const actionTier = (item) => {
    if ((item.tag === "DECIDE" || item.tag === "BLOCKED") && item.live) return 0;
    if (item.tag === "REVIEW") return 1;
    if (item.tag === "HOLD") return 2;
    return 3;
  };
  needsPedro.sort((left, right) => actionTier(left) - actionTier(right) || oldestFirst(left, right));
  underway.sort(oldestFirst);
  unhealthy.sort(oldestFirst);
  queued.sort(oldestFirst);
  unreadable.sort(oldestFirst);

  const model = {
    generated: snapshot.generated || "observation time absent",
    backlogPresent,
    telemetryPresent,
    buckets: [
      {
        key: "needs-pedro",
        name: "NEEDS PEDRO",
        htmlTitle: "Needs Pedro",
        tone: "attention",
        items: needsPedro,
        cap: 5,
        twoLine: true,
        rule: "rule: live asks, PRs, holds, oldest first",
        empty: backlogPresent ? "nothing needs you" : "backlog absent - captain holds unknown",
      },
      {
        key: "underway",
        name: "UNDERWAY",
        htmlTitle: "Underway",
        tone: "progress",
        items: underway,
        cap: 5,
        twoLine: false,
        empty: "nothing underway",
      },
      {
        key: "unhealthy",
        name: "UNHEALTHY",
        htmlTitle: "Unhealthy",
        tone: "danger",
        items: unhealthy,
        cap: 3,
        twoLine: true,
        empty: "no unhealthy worker visible",
      },
      {
        key: "queued",
        name: "QUEUED",
        htmlTitle: "Queued",
        tone: "neutral",
        items: queued,
        cap: 3,
        twoLine: false,
        empty: backlogPresent ? "queue empty" : "backlog absent - queue unknown",
      },
      {
        key: "unreadable",
        name: "UNREADABLE",
        htmlTitle: "Unreadable",
        tone: "neutral",
        items: unreadable,
        cap: 0,
        twoLine: false,
        foldWord: "unreadable right now, nothing evidences them as bad",
        hideWhenEmpty: true,
        empty: "",
      },
    ],
  };

  // Stable row numbers over the full sorted model, so a number seen in the
  // default view, in --all, and given to --show always means the same item.
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

const ANSI = { reset: "\u001b[0m", bold: "\u001b[1m", dim: "\u001b[2m", amber: "\u001b[33m", green: "\u001b[32m", red: "\u001b[31m", boldAmber: "\u001b[1;33m", boldRed: "\u001b[1;31m" };
const BUCKET_COLOR = { attention: "amber", progress: "green", danger: "red", neutral: "dim" };
const AGE_HOT_SECONDS = 7 * 86400;
const AGE_WARM_SECONDS = 3 * 86400;

function clip(text, width) {
  return text.length <= width ? text : `${text.slice(0, Math.max(0, width - 1))}…`;
}

function ageTier(item) {
  if (item.age.seconds === null) return "unknown";
  if (item.age.seconds >= AGE_HOT_SECONDS) return "hot";
  if (item.age.seconds >= AGE_WARM_SECONDS) return "warm";
  return "calm";
}

function ageSegment(item, paint) {
  const tier = ageTier(item);
  const text = tier === "hot" ? `⚠ ${item.age.label}` : item.age.label;
  const color = tier === "hot" ? "boldRed" : tier === "warm" ? "boldAmber" : "dim";
  return { plain: text, painted: paint(color, text) };
}

function renderTerminal(model, width, useColor, showAll) {
  const paint = (name, text) => (useColor && name ? `${ANSI[name]}${text}${ANSI.reset}` : text);
  const lines = [];
  lines.push(paint("bold", clip(`FIRSTMATE FLEET · observed ${model.generated}`, width)));
  lines.push(
    clip(
      `sources: backlog ${model.backlogPresent ? "present" : "absent"} · telemetry ${model.telemetryPresent ? "present" : "absent"} · token spend not measured`,
      width,
    ),
  );
  for (const bucket of model.buckets) {
    if (bucket.items.length === 0 && bucket.hideWhenEmpty) {
      continue;
    }
    lines.push("");
    const header = `── ${bucket.name} (${bucket.items.length}) `;
    const fill = "─".repeat(Math.max(0, width - header.length));
    lines.push(paint(BUCKET_COLOR[bucket.tone], clip(header + fill, width)));
    if (bucket.items.length === 0) {
      lines.push(clip(`   ${bucket.empty}`, width));
      continue;
    }
    const shown = showAll ? bucket.items : bucket.items.slice(0, bucket.cap);
    const numberWidth = String(model.totalRows).length;
    const headIndent = 2 + numberWidth + 1 + 8;
    for (const item of shown) {
      const tag = clip(item.tag, 7).padEnd(7);
      const rowLabel = String(item.number).padStart(numberWidth);
      const ageText = ageSegment(item, paint);
      const midParts = bucket.twoLine
        ? [item.name, item.project]
        : [item.name, item.project, item.note];
      const mid = midParts.filter(Boolean).join(" · ");
      const midWidth = Math.max(8, width - headIndent - 3 - ageText.plain.length);
      lines.push(
        `  ${paint("dim", rowLabel)} ${paint(BUCKET_COLOR[bucket.tone], tag)} ${clip(mid, midWidth)} · ${ageText.painted}`,
      );
      if (bucket.twoLine) {
        const detail = [item.prose, item.note].filter(Boolean).join("  ");
        if (detail) {
          lines.push(`${" ".repeat(headIndent)}${clip(detail, Math.max(0, width - headIndent))}`);
        }
      }
    }
    const hidden = bucket.items.length - shown.length;
    if (hidden > 0) {
      const ruleText = bucket.rule ? ` · ${bucket.rule}` : "";
      const foldWord = bucket.foldWord || "more";
      lines.push(paint("dim", clip(`  … ${hidden} ${foldWord}${ruleText} · --all shows all`, width)));
    }
  }
  return `${lines.join("\n")}\n`;
}

// Full single-item context for --show <n>: nothing truncated, every field
// sourced from data the cockpit already read.
function renderShow(model, requestedNumber) {
  const item = model.buckets.flatMap((bucket) => bucket.items).find((candidate) => candidate.number === requestedNumber);
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
  const tier = ageTier(item);
  const marker = tier === "hot" ? "⚠ " : "";
  return `<article class="card ${escapeHtml(tone)}">
    <p class="eyebrow">${escapeHtml([`#${item.number}`, item.tag, item.project].filter(Boolean).join(" · "))}</p>
    <h3>${escapeHtml(item.name || item.prose || "detail absent")}</h3>
    <div class="runtime"><strong class="age-${tier}">${escapeHtml(marker + item.age.label)}</strong>${detailMarkup}</div>
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
    .filter((bucket) => bucket.items.length > 0 || !bucket.hideWhenEmpty)
    .map(
      (bucket) => `<section id="${bucket.key}">
    <div class="section-head"><h2>${escapeHtml(bucket.htmlTitle)}</h2><p>${bucket.items.length} item${bucket.items.length === 1 ? "" : "s"}</p></div>
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
    .age-warm { color:var(--amber); }
    .empty { padding:18px; border:1px dashed var(--line); }
    @media (max-width:560px) { main { width:min(100% - 20px,1120px); padding-top:24px; } .section-head { display:grid; } }
  </style>
</head>
<body>
<main>
  <header>
    <p class="eyebrow">Firstmate · live state projection</p>
    <h1>Fleet Dashboard</h1>
    <p class="lede">Needs Pedro first; everything else is context.</p>
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

function collectInputs() {
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

  return { snapshot, telemetryRows, telemetryPresent };
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

try {
  const { outputPath, width, showAll, showRow } = parseArguments(process.argv.slice(2));
  if (outputPath !== null) {
    assertSafeOutput(outputPath);
  }
  const model = buildModel(collectInputs());
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
} catch (error) {
  process.stderr.write(`fm-fleet-dashboard: ${error.message}\n`);
  process.exit(1);
}
