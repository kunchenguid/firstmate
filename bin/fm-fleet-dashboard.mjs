#!/usr/bin/env node
// Generate the tracked, self-contained Fleet Dashboard from live Firstmate state.
//
// Sources stay read-only: fm-fleet-snapshot.sh owns meta/status classification,
// tasks-axi owns backlog projection, and fm-model-telemetry.sh owns its sheet.
// The only write is the requested HTML output, which defaults to the tracked
// repository path fleet-dashboard.html.

import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
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
const backlogPath = resolve(dataDirectory, "backlog.md");
const telemetryPath = resolve(dataDirectory, "routing-outcomes.jsonl");

function usage(stream = process.stdout) {
  stream.write(`usage: fm-fleet-dashboard.mjs [--output <path>]

Generate a self-contained HTML fleet dashboard.
The default output is ${resolve(repositoryRoot, "fleet-dashboard.html")}.
The output may never be written under data/, state/, or config/.
`);
}

function parseArguments(argumentsList) {
  let outputPath = resolve(repositoryRoot, "fleet-dashboard.html");
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "-h" || argument === "--help") {
      usage();
      process.exit(0);
    }
    if (argument === "--output" && index + 1 < argumentsList.length) {
      const supplied = argumentsList[index + 1];
      outputPath = isAbsolute(supplied) ? resolve(supplied) : resolve(process.cwd(), supplied);
      index += 1;
      continue;
    }
    usage(process.stderr);
    throw new Error(`unknown or incomplete argument: ${argument}`);
  }
  return { outputPath };
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

function parseCsvLikeRecord(line) {
  const fields = [];
  let current = "";
  let quoted = false;
  let escaped = false;
  for (const character of line) {
    if (escaped) {
      current += character;
      escaped = false;
      continue;
    }
    if (quoted && character === "\\") {
      current += character;
      escaped = true;
      continue;
    }
    if (character === '"') {
      current += character;
      quoted = !quoted;
      continue;
    }
    if (character === "," && !quoted) {
      fields.push(current.trim());
      current = "";
      continue;
    }
    current += character;
  }
  fields.push(current.trim());
  return fields;
}

function decodeToonValue(rawValue) {
  const value = rawValue.trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try {
      return JSON.parse(value).replaceAll("\n", " ");
    } catch {
      return value.slice(1, -1);
    }
  }
  if (value === "" || value === "none" || value === "-") {
    return null;
  }
  return value;
}

function parseTasksAxiList(output) {
  const lines = output.split(/\r?\n/);
  const headerIndex = lines.findIndex((line) => /^tasks\[\d+\]\{[^}]+\}:$/.test(line));
  if (headerIndex < 0) {
    return [];
  }
  const headerMatch = lines[headerIndex].match(/^tasks\[\d+\]\{([^}]+)\}:$/);
  const fieldNames = headerMatch[1].split(",");
  const records = [];
  for (const line of lines.slice(headerIndex + 1)) {
    if (!line.startsWith("  ")) {
      break;
    }
    const values = parseCsvLikeRecord(line.trim()).map(decodeToonValue);
    if (values.length !== fieldNames.length) {
      throw new Error("tasks-axi returned a row that does not match its declared fields");
    }
    records.push(Object.fromEntries(fieldNames.map((fieldName, index) => [fieldName, values[index]])));
  }
  return records;
}

function parseMeta(path) {
  if (!existsSync(path)) {
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

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function titleCase(value) {
  if (!value) {
    return "Absent";
  }
  return value.replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase());
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

function runtimeForTask(task, telemetryRows, generatedAt) {
  const meta = parseMeta(task.paths?.meta?.path);
  const attemptId = meta.telemetry_attempt || null;
  if (!attemptId || telemetryRows === null) {
    return { label: "Runtime absent", detail: "No joined telemetry attempt", sortSeconds: null };
  }
  const row = telemetryRows.find((candidate) => candidate.attemptId === attemptId);
  if (!row) {
    return { label: "Runtime absent", detail: "Telemetry attempt is absent", sortSeconds: null };
  }
  if (Number.isFinite(row.wallSeconds)) {
    const duration = formatDuration(row.wallSeconds);
    return {
      label: duration === null ? "Runtime absent" : `Ran for ${duration}`,
      detail: [row.harness, row.model, row.effort].filter(Boolean).join(" / ") || "Model tuple absent",
      sortSeconds: row.wallSeconds,
    };
  }
  const startedAt = Date.parse(row.startedAt || "");
  const observedAt = Date.parse(generatedAt || "");
  if (!Number.isFinite(startedAt) || !Number.isFinite(observedAt) || observedAt < startedAt) {
    return { label: "Runtime absent", detail: "Start or observation time is absent", sortSeconds: null };
  }
  const seconds = Math.floor((observedAt - startedAt) / 1000);
  return {
    label: `Running for ${formatDuration(seconds)}`,
    detail: [row.harness, row.model, row.effort].filter(Boolean).join(" / ") || "Model tuple absent",
    sortSeconds: seconds,
  };
}

function card({ eyebrow, title, detail, runtime, tone = "neutral" }) {
  const runtimeMarkup = runtime
    ? `<div class="runtime"><strong>${escapeHtml(runtime.label)}</strong><span>${escapeHtml(runtime.detail)}</span></div>`
    : "";
  return `<article class="card ${escapeHtml(tone)}">
    <p class="eyebrow">${escapeHtml(eyebrow)}</p>
    <h3>${escapeHtml(title)}</h3>
    <p>${escapeHtml(detail || "Detail absent")}</p>
    ${runtimeMarkup}
  </article>`;
}

function emptyState(message) {
  return `<p class="empty">${escapeHtml(message)}</p>`;
}

function sourceValue(label, value) {
  return `<div class="source"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderDashboard({ snapshot, captainHolds, telemetryRows, backlogPresent, telemetryPresent }) {
  const tasks = Array.isArray(snapshot.tasks) ? snapshot.tasks : [];
  const tasksWithRuntime = tasks.map((task) => ({
    ...task,
    runtime: runtimeForTask(task, telemetryRows, snapshot.generated),
  }));

  const statusDecisions = tasksWithRuntime.flatMap((task) =>
    (task.hints?.open_decisions || [])
      .filter((decision) => decision.verb === "needs-decision")
      .map((decision) => ({ task, decision })),
  );
  const actionableHolds = captainHolds.filter(
    (hold) => hold.hold_kind === "captain" && !hold.blocked_by,
  );
  const progressing = tasksWithRuntime.filter(
    (task) =>
      task.current_state?.state === "working" &&
      task.endpoint?.exists !== false &&
      !task.hints?.pending_decision,
  );
  const unhealthy = tasksWithRuntime.filter(
    (task) =>
      ["failed", "unknown"].includes(task.current_state?.state) ||
      task.endpoint?.exists === false ||
      task.endpoint?.agent_alive === "dead",
  );

  const needsPedroCards = [
    ...actionableHolds.map((hold) =>
      card({
        eyebrow: `${hold.repo || "Project absent"} · Captain hold`,
        title: hold.title || hold.id || "Untitled captain hold",
        detail: hold.hold_reason || "Hold reason absent",
        tone: "attention",
      }),
    ),
    ...statusDecisions.map(({ task, decision }) =>
      card({
        eyebrow: `${task.project || "Project absent"} · ${task.id}`,
        title: decision.summary || "Decision summary absent",
        detail: `Status decision ${decision.key || "default"}`,
        runtime: task.runtime,
        tone: "attention",
      }),
    ),
  ];
  const progressingCards = progressing.map((task) =>
    card({
      eyebrow: `${task.project || "Project absent"} · ${titleCase(task.kind)}`,
      title: task.id,
      detail: task.current_state?.detail || "Working detail absent",
      runtime: task.runtime,
      tone: "progress",
    }),
  );
  const unhealthyCards = unhealthy.map((task) =>
    card({
      eyebrow: `${task.project || "Project absent"} · ${titleCase(task.current_state?.state)}`,
      title: task.id,
      detail: task.current_state?.detail || task.endpoint?.status || "Health detail absent",
      runtime: task.runtime,
      tone: "danger",
    }),
  );
  const runtimeCards = [...tasksWithRuntime]
    .sort((left, right) => {
      if (left.runtime.sortSeconds === null && right.runtime.sortSeconds !== null) return 1;
      if (left.runtime.sortSeconds !== null && right.runtime.sortSeconds === null) return -1;
      return (right.runtime.sortSeconds || 0) - (left.runtime.sortSeconds || 0) || left.id.localeCompare(right.id);
    })
    .map((task) =>
      card({
        eyebrow: `${task.project || "Project absent"} · ${titleCase(task.current_state?.state)}`,
        title: task.id,
        detail: task.current_state?.detail || "Current detail absent",
        runtime: task.runtime,
      }),
    );

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
    .empty { padding:18px; border:1px dashed var(--line); }
    @media (max-width:560px) { main { width:min(100% - 20px,1120px); padding-top:24px; } .section-head { display:grid; } }
  </style>
</head>
<body>
<main>
  <header>
    <p class="eyebrow">Firstmate · live state projection</p>
    <h1>Fleet Dashboard</h1>
    <p class="lede">Four answers, generated from the fleet's authoritative read-only sources.</p>
    <p class="stamp">Observed ${escapeHtml(snapshot.generated || "observation time absent")}</p>
  </header>

  <div class="sources" aria-label="Source availability">
    ${sourceValue("Backlog source", backlogPresent ? "Present" : "Absent")}
    ${sourceValue("Model telemetry", telemetryPresent ? "Present" : "Absent")}
    ${sourceValue("Token spend", "Not measured")}
  </div>

  <section id="needs-pedro">
    <div class="section-head"><h2>Needs Pedro right now</h2><p>Captain holds and open decisions</p></div>
    <div class="grid">${needsPedroCards.join("") || emptyState(backlogPresent ? "Nothing currently needs Pedro." : "Backlog source is absent; status decisions are shown when present.")}</div>
  </section>

  <section id="progressing">
    <div class="section-head"><h2>Progressing on its own</h2><p>Verified working state</p></div>
    <div class="grid">${progressingCards.join("") || emptyState("No task is currently verified as working.")}</div>
  </section>

  <section id="unhealthy">
    <div class="section-head"><h2>Unhealthy</h2><p>Failed, unknown, missing, or dead</p></div>
    <div class="grid">${unhealthyCards.join("") || emptyState("No unhealthy task is visible.")}</div>
  </section>

  <section id="runtime">
    <div class="section-head"><h2>How long everything has been running</h2><p>Telemetry joins stay absent when unavailable</p></div>
    <div class="grid">${runtimeCards.join("") || emptyState("No task metadata is present, so runtimes are absent.")}</div>
  </section>
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

  const backlogPresent = existsSync(backlogPath);
  const captainHolds = backlogPresent
    ? parseTasksAxiList(
        run("tasks-axi", [
          "list",
          "--file",
          backlogPath,
          "--state",
          "held",
          "--limit",
          "10000",
          "--fields",
          "blocked_by,created,hold_kind,hold_reason,links",
        ]),
      )
    : [];

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

  return { snapshot, captainHolds, telemetryRows, backlogPresent, telemetryPresent };
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
  const { outputPath } = parseArguments(process.argv.slice(2));
  assertSafeOutput(outputPath);
  const inputs = collectInputs();
  const html = renderDashboard(inputs);
  writeAtomically(outputPath, html);
  process.stdout.write(`${outputPath}\n`);
} catch (error) {
  process.stderr.write(`fm-fleet-dashboard: ${error.message}\n`);
  process.exit(1);
}
