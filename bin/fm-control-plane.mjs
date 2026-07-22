#!/usr/bin/env node
// Evidence-backed reconciliation engine for bin/fm-control-plane.sh.
//
// This engine intentionally retains metadata and exact source pointers only.
// It never retains transcript message bodies, credential values, or arbitrary
// command output. docs/control-plane.md owns the data contracts and guarantee
// boundary; this file owns parsing and derivation mechanics.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const SOURCE_SCHEMA = "fm-control-plane-sources.v1";
const CONTROL_SCHEMA = "fm-control-item.v1";
const OUTPUT_SCHEMA = "fm-control-plane.v1";
const STAGES = [
  "implemented",
  "validated",
  "release_ready",
  "in_production",
  "real_users",
  "revenue",
];
const SOURCE_KINDS = new Set([
  "firstmate-home",
  "git-project",
  "worktree",
  "claude-session",
  "codex-session",
  "claude-transcript-root",
  "codex-transcript-root",
]);
const SEVERITY_ORDER = { critical: 0, high: 1, medium: 2, low: 3, none: 4 };
const SECRET_KEY = /(?:^|[_-])(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)(?:$|[_-])/i;
const SECRET_VALUE = /(?:\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bsk-[A-Za-z0-9_-]{16,}\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b)/g;

function fail(message, code = 2) {
  process.stderr.write(`fm-control-plane: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const args = {
    root: "",
    home: "",
    sources: "",
    snapshot: "",
    now: "",
    output: "human",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (["--root", "--home", "--sources", "--snapshot", "--now"].includes(arg)) {
      if (i + 1 >= argv.length) fail(`${arg} requires a value`);
      args[arg.slice(2)] = argv[i + 1];
      i += 1;
    } else if (arg === "--json") {
      args.output = "json";
    } else if (arg === "--attention-fingerprint") {
      args.output = "fingerprint";
    } else if (arg === "-h" || arg === "--help") {
      process.stdout.write(
        "usage: fm-control-plane.sh [--sources <path>] [--json]\n" +
        "       fm-control-plane.sh [--sources <path>] --attention-fingerprint\n",
      );
      process.exit(0);
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  if (!args.root || !args.home) fail("--root and --home are required");
  if (!args.sources) args.sources = path.join(args.home, "config", "control-plane-sources.json");
  return args;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${label} is unreadable or invalid JSON: ${error.message}`);
  }
}

function hasSecret(value, trail = []) {
  if (typeof value === "string") {
    SECRET_VALUE.lastIndex = 0;
    if (SECRET_VALUE.test(value)) return trail.join(".") || "<root>";
    return null;
  }
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i += 1) {
      const found = hasSecret(value[i], [...trail, String(i)]);
      if (found) return found;
    }
    return null;
  }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      if (SECRET_KEY.test(key)) return [...trail, key].join(".");
      const found = hasSecret(child, [...trail, key]);
      if (found) return found;
    }
  }
  return null;
}

function redactText(value, max = 240) {
  let text = String(value ?? "").replace(/[\t\r\n]+/g, " ");
  SECRET_VALUE.lastIndex = 0;
  text = text.replace(SECRET_VALUE, "[REDACTED]");
  text = text.replace(/\b(password|token|secret|api[_-]?key)\s*[:=]\s*\S+/gi, "$1=[REDACTED]");
  if (text.length > max) text = `${text.slice(0, max - 1)}…`;
  return text;
}

function sha(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function iso(epochMs) {
  return new Date(epochMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function epochOf(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value < 10_000_000_000 ? value * 1000 : value;
  }
  const parsed = Date.parse(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function strictIsoTimestamp(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(trimmed)) return null;
  const parsed = Date.parse(trimmed);
  return Number.isFinite(parsed) && iso(parsed) === trimmed ? parsed : null;
}

function statSafe(target) {
  try {
    const stat = fs.statSync(target);
    return { exists: true, stat, observedAt: iso(stat.mtimeMs) };
  } catch {
    return { exists: false, stat: null, observedAt: null };
  }
}

function realSafe(target) {
  try {
    return fs.realpathSync(target);
  } catch {
    return path.resolve(target);
  }
}

function expandLocator(locator, args) {
  if (typeof locator !== "string" || locator.length === 0) return "";
  const replacements = {
    "${HOME}": process.env.HOME || "",
    "${FM_HOME}": args.home,
    "${FM_ROOT}": args.root,
  };
  let result = locator;
  for (const [token, value] of Object.entries(replacements)) result = result.split(token).join(value);
  if (/\$\{[^}]+\}/.test(result)) throw new Error(`unsupported path token in ${locator}`);
  return path.resolve(result);
}

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, {
    encoding: "utf8",
    maxBuffer: options.maxBuffer || 8 * 1024 * 1024,
    cwd: options.cwd,
    env: options.env || process.env,
    timeout: options.timeout || 10_000,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error,
  };
}

function readChunk(file, start, length) {
  const fd = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytes = fs.readSync(fd, buffer, 0, length, start);
    return buffer.subarray(0, bytes).toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

function jsonLines(text) {
  const records = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      // A bounded head or tail can begin or end in the middle of a line.
    }
  }
  return records;
}

function transcriptMetadata(file, provider, configuredId = "") {
  const stat = fs.statSync(file);
  const head = readChunk(file, 0, Math.min(stat.size, 131_072));
  const tailStart = Math.max(0, stat.size - 524_288);
  const tail = readChunk(file, tailStart, Math.min(stat.size, 524_288));
  const records = [...jsonLines(head), ...jsonLines(tail)];
  let sessionId = configuredId || path.basename(file, ".jsonl");
  let cwd = "";
  let observed = stat.mtimeMs;
  for (const record of records) {
    if (provider === "codex") {
      if (record?.type === "session_meta") {
        sessionId = configuredId || record.payload?.id || record.payload?.session_id || sessionId;
        cwd = record.payload?.cwd || cwd;
      }
      observed = Math.max(observed, epochOf(record?.timestamp) || 0);
    } else {
      sessionId = configuredId || record?.sessionId || sessionId;
      cwd = record?.cwd || cwd;
      observed = Math.max(observed, epochOf(record?.timestamp) || 0);
    }
  }
  return {
    provider,
    session_id: sessionId,
    path: realSafe(file),
    cwd: cwd ? realSafe(cwd) : null,
    observed_at: iso(observed),
    observed_epoch: observed,
    bytes: stat.size,
  };
}

function walkRecentJsonl(root, sinceEpoch, maxFiles, provider) {
  const found = [];
  const stack = [root];
  const maxPaths = Math.max(1_000, maxFiles * 20);
  let scannedPaths = 0;
  while (stack.length > 0 && found.length < maxFiles * 4 && scannedPaths < maxPaths) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      scannedPaths += 1;
      if (scannedPaths > maxPaths) break;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "subagents" || entry.name === "tool-results") continue;
        stack.push(full);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        if (provider === "claude" && path.basename(path.dirname(full)).match(/^[0-9a-f-]{36}$/i)) continue;
        const stat = statSafe(full);
        if (stat.exists && stat.stat.mtimeMs >= sinceEpoch) found.push({ path: full, mtime: stat.stat.mtimeMs });
      }
    }
  }
  return {
    files: found.sort((a, b) => b.mtime - a.mtime).slice(0, maxFiles),
    scanned_paths: scannedPaths,
    max_files: maxFiles,
    truncated: stack.length > 0 || found.length > maxFiles || scannedPaths > maxPaths,
  };
}

function parseWorktrees(projectPath) {
  const result = run("git", ["-C", projectPath, "worktree", "list", "--porcelain"], { timeout: 10_000 });
  if (!result.ok) throw new Error(redactText(result.stderr || "git worktree list failed"));
  const rows = [];
  let row = null;
  for (const line of result.stdout.split(/\r?\n/)) {
    if (line.startsWith("worktree ")) {
      if (row) rows.push(row);
      row = { path: realSafe(line.slice(9)), head: null, branch: null, detached: false, bare: false };
    } else if (row && line.startsWith("HEAD ")) row.head = line.slice(5);
    else if (row && line.startsWith("branch ")) row.branch = line.slice(7).replace("refs/heads/", "");
    else if (row && line === "detached") row.detached = true;
    else if (row && line === "bare") row.bare = true;
  }
  if (row) rows.push(row);
  return rows;
}

function gitProject(source, args, nowIso) {
  const locator = expandLocator(source.path, args);
  const observed = statSafe(locator);
  if (!observed.exists) return { sourceStatus: "unavailable", project: null, worktrees: [], error: "path absent" };
  const top = run("git", ["-C", locator, "rev-parse", "--show-toplevel"]);
  const common = run("git", ["-C", locator, "rev-parse", "--git-common-dir"]);
  if (!top.ok || !common.ok) {
    return { sourceStatus: "unavailable", project: null, worktrees: [], error: "not a readable git project" };
  }
  const root = realSafe(top.stdout.trim());
  const commonPath = path.resolve(root, common.stdout.trim());
  const worktrees = parseWorktrees(root);
  const statePath = path.join(root, "state.md");
  const handoffDir = path.join(root, ".ai");
  let positionUpdated = null;
  if (fs.existsSync(statePath)) {
    const head = fs.readFileSync(statePath, "utf8").slice(0, 65_536);
    const match = head.match(/^updated:\s*(.+)$/im) || head.match(/^[-*]\s*Updated:\s*(.+)$/im);
    positionUpdated = match ? (epochOf(match[1].trim()) ?? fs.statSync(statePath).mtimeMs) : fs.statSync(statePath).mtimeMs;
  }
  let handoff = null;
  if (fs.existsSync(handoffDir)) {
    const candidates = fs.readdirSync(handoffDir)
      .filter((name) => /^HANDOFF-.*\.md$/.test(name))
      .map((name) => {
        const file = path.join(handoffDir, name);
        return { path: realSafe(file), epoch: fs.statSync(file).mtimeMs };
      })
      .sort((a, b) => b.epoch - a.epoch);
    handoff = candidates[0] || null;
  }
  const projectId = `project:${source.id}`;
  return {
    sourceStatus: "available",
    error: null,
    project: {
      id: projectId,
      stable_id: `git:${sha(realSafe(commonPath)).slice(0, 24)}`,
      name: source.name || source.id,
      path: root,
      git_common_dir: realSafe(commonPath),
      source_id: source.id,
      trust_domain: source.trust_domain,
      observed_at: nowIso,
      freshness: "fresh",
      continuity: {
        position: fs.existsSync(statePath)
          ? { path: realSafe(statePath), observed_at: iso(positionUpdated), freshness: "observed" }
          : { path: realSafe(statePath), observed_at: null, freshness: "unknown" },
        handoff: handoff
          ? { path: handoff.path, observed_at: iso(handoff.epoch), freshness: "observed" }
          : { path: realSafe(handoffDir), observed_at: null, freshness: "unknown" },
      },
    },
    worktrees: worktrees.map((item) => ({
      id: `worktree:${sha(`${realSafe(commonPath)}\0${item.path}`).slice(0, 24)}`,
      stable_id: `git-worktree:${sha(`${realSafe(commonPath)}\0${item.path}`).slice(0, 24)}`,
      project_id: projectId,
      source_id: source.id,
      ...item,
      registered: item.path === root,
      registration_source: item.path === root ? source.id : null,
      observed_at: nowIso,
      freshness: "fresh",
    })),
  };
}

function firstmateSnapshot(source, args) {
  if (args.snapshot) return readJson(args.snapshot, "snapshot fixture");
  if (source.snapshot_path) return readJson(expandLocator(source.snapshot_path, args), "snapshot source");
  const home = expandLocator(source.path, args);
  const script = path.join(args.root, "bin", "fm-fleet-snapshot.sh");
  const env = {
    ...process.env,
    FM_HOME: home,
    FM_ROOT_OVERRIDE: args.root,
    FM_SNAPSHOT_NO_BACKEND: source.backend_observation === true ? "0" : "1",
  };
  const result = run(script, ["--json"], { env, timeout: source.timeout_seconds ? source.timeout_seconds * 1000 : 30_000 });
  if (!result.ok) throw new Error(redactText(result.stderr || "fleet snapshot failed"));
  return JSON.parse(result.stdout);
}

function sourceRecord(source, locator, status, observedAt, nowEpoch, detail = null) {
  const freshnessSeconds = Number(source.freshness_seconds || 0);
  const observedEpoch = epochOf(observedAt);
  const age = observedEpoch ? Math.max(0, Math.floor((nowEpoch - observedEpoch) / 1000)) : null;
  let finalStatus = status;
  if (status === "available" && freshnessSeconds > 0 && age !== null && age > freshnessSeconds) finalStatus = "stale";
  return {
    id: source.id,
    kind: source.kind,
    status: source.enabled === false ? "disabled" : finalStatus,
    trust_domain: source.trust_domain,
    access: source.access,
    retention: source.retention,
    capabilities: source.capabilities || [],
    locator: locator || null,
    observed_at: observedAt || null,
    freshness_seconds: freshnessSeconds || null,
    age_seconds: age,
    detail: detail ? redactText(detail) : null,
  };
}

function normalizeSnapshotTasks(snapshot, source, nowIso) {
  const home = realSafe(snapshot.fm_home || source.path);
  const byId = new Map();
  for (const task of snapshot.tasks || []) {
    byId.set(task.id, {
      id: `task:${sha(`${home}\0${task.id}`).slice(0, 24)}`,
      task_id: task.id,
      stable_id: `firstmate-task:${sha(`${home}\0${task.id}`).slice(0, 24)}`,
      source_id: source.id,
      fm_home: home,
      kind: task.kind || "ship",
      project: task.project || task.backlog?.repo || null,
      worktree: task.paths?.worktree?.path || null,
      worktree_present: task.paths?.worktree?.present === true,
      current_state: {
        state: task.current_state?.state || "unknown",
        classification: task.current_state?.source === "run-step" || task.current_state?.source === "pane" ? "proved" : "unknown",
        source: task.current_state?.source || "none",
        detail: redactText(task.current_state?.detail || ""),
        observed_at: task.current_state?.observed_at || nowIso,
        freshness: task.current_state?.freshness || "unknown",
      },
      endpoint: task.endpoint || { status: "unknown", observed_at: nowIso, freshness: "unknown" },
      pr: task.pr || { url: null, source: "absent" },
      decisions: task.hints?.open_decisions || [],
      historical_event: redactText(task.hints?.last_event_text || ""),
      backlog: task.backlog || null,
      mode: task.mode || "",
      yolo: task.yolo || "",
      observed_at: nowIso,
      freshness: "fresh",
    });
  }
  for (const record of snapshot.backlog?.records || []) {
    if (!record.structured || !record.id || !["in_flight", "queued", "done"].includes(record.state)) continue;
    if (byId.has(record.id)) continue;
    byId.set(record.id, {
      id: `task:${sha(`${home}\0${record.id}`).slice(0, 24)}`,
      task_id: record.id,
      stable_id: `firstmate-task:${sha(`${home}\0${record.id}`).slice(0, 24)}`,
      source_id: source.id,
      fm_home: home,
      kind: record.kind || "ship",
      project: record.repo || null,
      worktree: null,
      worktree_present: false,
      current_state: { state: record.state === "done" ? "done" : "unknown", classification: record.state === "done" ? "inferred" : "unknown", source: "backlog", detail: "", observed_at: nowIso, freshness: "fresh" },
      endpoint: { status: "unknown", observed_at: nowIso, freshness: "unknown" },
      pr: { url: record.pr_url || null, source: record.pr_url ? "backlog" : "absent" },
      decisions: [],
      historical_event: "",
      backlog: record,
      mode: "",
      yolo: "",
      observed_at: nowIso,
      freshness: "fresh",
    });
  }
  return [...byId.values()].sort((a, b) => a.task_id.localeCompare(b.task_id));
}

function validateControl(control, taskId) {
  if (control.schema !== CONTROL_SCHEMA) throw new Error(`control record for ${taskId} has unsupported schema`);
  if (control.id !== taskId) throw new Error(`control record id ${control.id || "<missing>"} does not match ${taskId}`);
  if (control.updated_at != null && strictIsoTimestamp(control.updated_at) === null) {
    throw new Error(`control record for ${taskId} has invalid updated_at`);
  }
  const secret = hasSecret(control);
  if (secret) throw new Error(`control record for ${taskId} contains secret-like material at ${secret}`);
  return control;
}

function controlFreshness(control, nowEpoch) {
  if (!control) return { status: "unknown", observed_at: null, age_seconds: null };
  const observedEpoch = epochOf(control.updated_at);
  const expectation = Number(control.freshness_seconds || 0);
  if (!observedEpoch || expectation <= 0) return { status: "unknown", observed_at: control.updated_at || null, age_seconds: null };
  const age = Math.max(0, Math.floor((nowEpoch - observedEpoch) / 1000));
  return { status: age > expectation ? "stale" : "fresh", observed_at: iso(observedEpoch), age_seconds: age };
}

function verifyProof(proof, projectsBySource, args, nowEpoch) {
  const observedEpoch = epochOf(proof.observed_at);
  const freshnessSeconds = Number(proof.freshness_seconds || 0);
  const stale = observedEpoch && freshnessSeconds > 0 && nowEpoch - observedEpoch > freshnessSeconds * 1000;
  if (proof.kind === "file") {
    const pointer = expandLocator(proof.pointer || "", args);
    const stat = statSafe(pointer);
    return { status: stat.exists ? (stale ? "stale" : "proved") : "unknown", pointer, observed_at: stat.observedAt || proof.observed_at || null, source: proof.source || "filesystem" };
  }
  if (proof.kind === "git_commit") {
    const project = projectsBySource.get(proof.project_source_id || "");
    if (!project || !proof.ref) return { status: "unknown", pointer: proof.ref || null, observed_at: proof.observed_at || null, source: proof.source || "git" };
    const result = run("git", ["-C", project.path, "cat-file", "-e", `${proof.ref}^{commit}`]);
    return { status: result.ok ? (stale ? "stale" : "proved") : "unknown", pointer: `${project.path}@${proof.ref}`, observed_at: proof.observed_at || null, source: proof.source || "git" };
  }
  if (proof.kind === "external_record") {
    const result = proof.result === "proved" ? (stale ? "stale" : "proved") : proof.result === "absent" ? "absent" : "unknown";
    return { status: result, pointer: proof.pointer || null, observed_at: proof.observed_at || null, source: proof.source || "external" };
  }
  return { status: "unknown", pointer: proof.pointer || null, observed_at: proof.observed_at || null, source: proof.source || "unknown" };
}

function outcomeFor(control, projectsBySource, args, nowEpoch) {
  const requirements = control?.proof_requirements || null;
  const proofs = Array.isArray(control?.proofs) ? control.proofs : [];
  const stages = STAGES.map((stage) => {
    const requirement = requirements?.[stage];
    if (!requirement) return { stage, required: null, status: "unknown", reason: "proof requirement missing", evidence: [] };
    if (requirement.required === false) return { stage, required: false, status: "not_applicable", reason: redactText(requirement.reason || "explicitly not applicable"), evidence: [] };
    const evidence = proofs.filter((proof) => proof.stage === stage).map((proof) => verifyProof(proof, projectsBySource, args, nowEpoch));
    let status = "unknown";
    if (evidence.some((entry) => entry.status === "proved")) status = "proved";
    else if (evidence.some((entry) => entry.status === "stale")) status = "stale";
    else if (evidence.some((entry) => entry.status === "absent")) status = "absent";
    return { stage, required: true, status, reason: status === "unknown" ? "required proof absent" : null, evidence };
  });
  let furthest = "active";
  for (const stage of stages) {
    if (stage.status === "proved") furthest = stage.stage;
    else if (stage.required !== false) break;
  }
  return { furthest_proved_stage: furthest, stages };
}

function hasIncompleteRequiredStages(outcome) {
  return outcome.stages.some((stage) => stage.required !== false && stage.status !== "proved");
}

function violation(code, subjectId, message, severity = "high", sourceIds = []) {
  return {
    id: `violation:${sha(`${code}\0${subjectId}`).slice(0, 24)}`,
    code,
    subject_id: subjectId,
    severity,
    message: redactText(message),
    source_ids: [...new Set(sourceIds)],
  };
}

function attentionEntry(kind, subjectId, title, severity, reason, capability = null, authority = null) {
  return {
    id: `attention:${sha(`${kind}\0${subjectId}\0${reason}`).slice(0, 24)}`,
    kind,
    subject_id: subjectId,
    title: redactText(title, 160),
    severity,
    reason: redactText(reason),
    capability,
    authority,
  };
}

function matchesProject(cwd, project, worktrees) {
  if (!cwd) return false;
  const target = realSafe(cwd);
  const roots = [project.path, ...worktrees.filter((item) => item.project_id === project.id).map((item) => item.path)];
  return roots.some((root) => target === root || target.startsWith(`${root}${path.sep}`));
}

function renderHuman(result) {
  const lines = [];
  const pushList = (items, empty) => {
    if (items.length === 0) lines.push(empty);
    else for (const item of items) lines.push(`- ${item.title}: ${item.reason}`);
  };
  lines.push("# Operating Control Plane", "", `Evidence observed: ${result.generated}`, `Registered scope: ${result.scope.id}`, "");
  lines.push("## What matters now", "");
  pushList(result.orientation.what_matters_now, "No new high-priority attention from registered sources.");
  lines.push("", "## Progressing", "");
  pushList(result.orientation.progressing, "No work has fresh positive progress evidence.");
  lines.push("", "## Stuck or waiting", "");
  pushList(result.orientation.stuck, "No registered work is proved stuck or waiting.");
  lines.push("", "## Needs the captain", "");
  pushList(result.orientation.needs_captain, "No current captain decision or authority gate is proved.");
  lines.push("", "## Safe next actions", "");
  pushList(result.orientation.safe_next, "No explicit next action is both authorized and unblocked.");
  lines.push("", "## Missing proof", "");
  pushList(result.orientation.no_proof, "No required outcome proof is missing.");
  lines.push("", "## Registered source coverage", "");
  for (const source of result.source_registry.sources) lines.push(`- ${source.id} (${source.kind}): ${source.status}`);
  for (const connector of result.source_registry.connectors) lines.push(`- ${connector.id} (${connector.kind}): ${connector.status}`);
  lines.push("", `Invariant status: ${result.invariants.status} (${result.invariants.violations.length} violations)`);
  return `${lines.join("\n")}\n`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const nowEpoch = args.now ? epochOf(args.now) : Date.now();
  if (!nowEpoch) fail("--now must be an ISO-8601 timestamp");
  const nowIso = iso(nowEpoch);
  if (!fs.existsSync(args.sources)) fail(`source registry absent: ${args.sources}`);
  let registry;
  try {
    registry = readJson(args.sources, "source registry");
  } catch (error) {
    fail(error.message);
  }
  if (registry.schema !== SOURCE_SCHEMA) fail(`unsupported source registry schema: ${registry.schema || "<missing>"}`);
  const secret = hasSecret(registry);
  if (secret) fail(`source registry contains secret-like material at ${secret}`, 3);
  if (!registry.scope?.id || !Array.isArray(registry.sources)) fail("source registry requires scope.id and sources[]");
  const ids = new Set();
  for (const source of registry.sources) {
    if (!source.id || !source.kind || !source.trust_domain || !source.access || !source.retention) fail("every source requires id, kind, trust_domain, access, and retention");
    if (!SOURCE_KINDS.has(source.kind)) fail(`unsupported source kind: ${source.kind}`);
    if (!source.path) fail(`source ${source.id} requires path`);
    if (!Number.isFinite(Number(source.freshness_seconds)) || Number(source.freshness_seconds) <= 0) fail(`source ${source.id} requires a positive freshness_seconds`);
    if (!Array.isArray(source.capabilities)) fail(`source ${source.id} requires capabilities[]`);
    if (ids.has(source.id)) fail(`duplicate source id: ${source.id}`);
    ids.add(source.id);
  }
  if (registry.connectors !== undefined && !Array.isArray(registry.connectors)) fail("connectors must be an array");
  for (const connector of registry.connectors || []) {
    if (!connector.id || !connector.kind || !connector.status || !connector.trust_domain || !Array.isArray(connector.capabilities)) fail("every connector requires id, kind, status, trust_domain, and capabilities[]");
  }

  const sourceRecords = [];
  const projects = [];
  const worktrees = [];
  const tasks = [];
  const sessionsByKey = new Map();
  const firstmateHomes = [];
  const violations = [];
  const observations = [];
  const judgments = [];
  const projectsBySource = new Map();

  for (const source of registry.sources) {
    if (source.enabled === false) {
      sourceRecords.push(sourceRecord(source, source.path || null, "disabled", null, nowEpoch));
      continue;
    }
    let locator = "";
    try {
      locator = source.path ? expandLocator(source.path, args) : "";
      if (source.kind === "git-project") {
        const result = gitProject(source, args, nowIso);
        sourceRecords.push(sourceRecord(source, locator, result.sourceStatus, nowIso, nowEpoch, result.error));
        if (result.project) {
          projects.push(result.project);
          projectsBySource.set(source.id, result.project);
          worktrees.push(...result.worktrees);
        }
      } else if (source.kind === "firstmate-home") {
        const stat = statSafe(locator);
        if (!stat.exists) {
          sourceRecords.push(sourceRecord(source, locator, "unavailable", null, nowEpoch, "home absent"));
          continue;
        }
        const snapshot = firstmateSnapshot(source, args);
        if (snapshot.schema !== "fm-fleet-snapshot.v1") throw new Error("unsupported fleet snapshot schema");
        sourceRecords.push(sourceRecord(source, locator, "available", snapshot.generated || nowIso, nowEpoch));
        firstmateHomes.push({ source, path: locator, snapshot });
        tasks.push(...normalizeSnapshotTasks(snapshot, source, nowIso));
      } else if (source.kind === "claude-session" || source.kind === "codex-session") {
        const provider = source.kind.startsWith("claude") ? "claude" : "codex";
        const stat = statSafe(locator);
        if (!stat.exists) {
          sourceRecords.push(sourceRecord(source, locator, "unavailable", null, nowEpoch, "transcript absent"));
          continue;
        }
        const metadata = transcriptMetadata(locator, provider, source.session_id || "");
        const key = `${provider}:${metadata.session_id}`;
        const session = {
          id: `session:${provider}:${metadata.session_id}`,
          stable_id: `native-session:${provider}:${metadata.session_id}`,
          source_ids: [source.id],
          registered: true,
          registration_source: source.id,
          project_source_id: source.project_source_id || null,
          work_item_id: source.work_item_id || null,
          runtime: source.runtime_observation ? {
            state: source.runtime_observation.state || "unknown",
            source: source.runtime_observation.source || source.id,
            observed_at: source.runtime_observation.observed_at || null,
            classification: epochOf(source.runtime_observation.observed_at) ? "inferred" : "unknown",
            endpoint: source.runtime_observation.endpoint || null,
          } : { state: "unknown", source: null, observed_at: null, classification: "unknown" },
          ...metadata,
        };
        const existing = sessionsByKey.get(key);
        if (existing) {
          session.source_ids = [...new Set([...existing.source_ids, source.id])];
          session.registration_source = existing.registration_source || source.id;
          const projectConflict = existing.project_source_id && session.project_source_id && existing.project_source_id !== session.project_source_id;
          const workItemConflict = existing.work_item_id && session.work_item_id && existing.work_item_id !== session.work_item_id;
          if (projectConflict || workItemConflict) {
            violations.push(violation("SESSION_REGISTRATION_CONFLICT", session.id, `${provider} session ${metadata.session_id} has conflicting durable registrations`, "critical", session.source_ids));
            session.project_source_id = null;
            session.work_item_id = null;
            session.registration_conflict = true;
          }
        }
        sessionsByKey.set(key, { ...existing, ...session });
        sourceRecords.push(sourceRecord(source, locator, "available", metadata.observed_at, nowEpoch));
      } else if (source.kind === "claude-transcript-root" || source.kind === "codex-transcript-root") {
        const stat = statSafe(locator);
        if (!stat.exists) {
          sourceRecords.push(sourceRecord(source, locator, "unavailable", null, nowEpoch, "transcript root absent"));
          continue;
        }
        sourceRecords.push(sourceRecord(source, locator, "available", nowIso, nowEpoch));
      } else if (source.kind === "worktree") {
        const stat = statSafe(locator);
        sourceRecords.push(sourceRecord(source, locator, stat.exists ? "available" : "unavailable", stat.observedAt, nowEpoch, stat.exists ? null : "worktree absent"));
      } else {
        sourceRecords.push(sourceRecord(source, locator, "unavailable", null, nowEpoch, "unsupported source kind"));
      }
    } catch (error) {
      sourceRecords.push(sourceRecord(source, locator, "unavailable", null, nowEpoch, error.message));
    }
  }

  for (const source of registry.sources) {
    if (source.enabled === false || !["claude-transcript-root", "codex-transcript-root"].includes(source.kind)) continue;
    const provider = source.kind.startsWith("claude") ? "claude" : "codex";
    const locator = expandLocator(source.path, args);
    if (!statSafe(locator).exists) continue;
    const lookback = Number(source.lookback_seconds || 86_400);
    const maxFiles = Number(source.max_files || 200);
    const allowedProjects = projects.filter((project) => !source.project_source_ids || source.project_source_ids.includes(project.source_id));
    const discovery = walkRecentJsonl(locator, nowEpoch - lookback * 1000, maxFiles, provider);
    const sourceStatus = sourceRecords.find((record) => record.id === source.id);
    if (sourceStatus) sourceStatus.discovery = { scanned_paths: discovery.scanned_paths, candidates: discovery.files.length, max_files: discovery.max_files, truncated: discovery.truncated };
    for (const candidate of discovery.files) {
      let metadata;
      try {
        metadata = transcriptMetadata(candidate.path, provider);
      } catch {
        continue;
      }
      const project = allowedProjects.find((item) => matchesProject(metadata.cwd, item, worktrees));
      if (!project) continue;
      const key = `${provider}:${metadata.session_id}`;
      const existing = sessionsByKey.get(key);
      if (existing) {
        existing.source_ids = [...new Set([...existing.source_ids, source.id])];
        if (!existing.project_source_id) existing.project_source_id = project.source_id;
      } else {
        sessionsByKey.set(key, {
          id: `session:${provider}:${metadata.session_id}`,
          stable_id: `native-session:${provider}:${metadata.session_id}`,
          source_ids: [source.id],
          registered: false,
          registration_source: null,
          project_source_id: project.source_id,
          work_item_id: null,
          runtime: { state: "unknown", source: null, observed_at: null, classification: "unknown" },
          ...metadata,
        });
      }
    }
  }

  const sessions = [...sessionsByKey.values()].sort((a, b) => a.stable_id.localeCompare(b.stable_id));
  const taskByItemId = new Map(tasks.map((task) => [task.task_id, task]));
  for (const task of tasks) {
    if (!task.worktree) continue;
    const target = realSafe(task.worktree);
    const worktree = worktrees.find((item) => item.path === target);
    if (worktree) {
      worktree.registered = true;
      worktree.registration_source = task.source_id;
      worktree.task_id = task.task_id;
    }
  }
  for (const source of registry.sources.filter((item) => item.kind === "worktree" && item.enabled !== false)) {
    const target = realSafe(expandLocator(source.path, args));
    const worktree = worktrees.find((item) => item.path === target);
    if (worktree) {
      worktree.registered = true;
      worktree.registration_source = source.id;
    } else violations.push(violation("WORKTREE_REGISTRATION_UNRESOLVED", `source:${source.id}`, `${source.id} does not match a worktree in a registered git project`, "critical", [source.id]));
  }

  const controlByTask = new Map();
  for (const home of firstmateHomes) {
    for (const task of tasks.filter((item) => item.source_id === home.source.id)) {
      const controlPath = path.join(home.path, "data", task.task_id, "control.json");
      if (!fs.existsSync(controlPath)) continue;
      try {
        controlByTask.set(task.task_id, { control: validateControl(readJson(controlPath, `control record ${task.task_id}`), task.task_id), path: realSafe(controlPath) });
      } catch (error) {
        violations.push(violation("CONTROL_RECORD_INVALID", task.id, error.message, "critical", [task.source_id]));
      }
    }
  }

  const workItems = [];
  for (const task of tasks) {
    const controlRecord = controlByTask.get(task.task_id);
    const control = controlRecord?.control || null;
    const owner = control?.owner || (task.worktree || task.current_state.source !== "backlog" ? { type: "firstmate-task", id: task.task_id, source: task.source_id } : null);
    const authority = control?.authority || (task.mode ? { level: task.yolo === "on" ? "routine" : "captain", source: "firstmate-task-meta", delivery: task.mode } : null);
    const nextAction = control?.next_action || null;
    const outcome = outcomeFor(control, projectsBySource, args, nowEpoch);
    const controlState = controlFreshness(control, nowEpoch);
    const item = {
      id: task.id,
      task_id: task.task_id,
      title: redactText(control?.title || task.backlog?.title || task.task_id, 160),
      purpose: control?.purpose ? redactText(control.purpose) : null,
      business_outcome: control?.business_outcome ? redactText(control.business_outcome) : null,
      capability: control?.capability || null,
      owner,
      next_action: nextAction ? { description: redactText(nextAction.description || ""), capability: nextAction.capability || null } : null,
      authority,
      freshness_seconds: Number(control?.freshness_seconds || 0) || null,
      control_state: controlState,
      control_path: controlRecord?.path || null,
      current_state: task.current_state,
      backlog_state: task.backlog?.state || null,
      decisions: task.decisions,
      outcome,
    };
    workItems.push(item);
    if (!owner) violations.push(violation("WORK_ITEM_OWNER_MISSING", item.id, `${item.task_id} has no accountable owner`, "critical", [task.source_id]));
    if (!nextAction?.description || !nextAction?.capability) violations.push(violation("WORK_ITEM_NEXT_ACTION_MISSING", item.id, `${item.task_id} has no explicit atomic next action`, "high", [task.source_id]));
    if (!control?.proof_requirements || STAGES.some((stage) => !control.proof_requirements[stage])) violations.push(violation("WORK_ITEM_PROOF_REQUIREMENT_MISSING", item.id, `${item.task_id} has no complete stage-by-stage proof definition`, "critical", [task.source_id]));
    if (!authority?.level) violations.push(violation("WORK_ITEM_AUTHORITY_MISSING", item.id, `${item.task_id} has no explicit authority level`, "critical", [task.source_id]));
    if (!control?.updated_at || !item.freshness_seconds) violations.push(violation("WORK_ITEM_FRESHNESS_MISSING", item.id, `${item.task_id} has no explicit control-record freshness expectation`, "high", [task.source_id]));
    else if (controlState.status === "stale") violations.push(violation("WORK_ITEM_CONTROL_STALE", item.id, `${item.task_id} control record exceeds its freshness expectation`, "high", [task.source_id]));
    const claimedComplete = task.backlog?.state === "done" || task.current_state.state === "done" || /^done:/i.test(task.historical_event);
    const implemented = outcome.stages.find((stage) => stage.stage === "implemented");
    const validated = outcome.stages.find((stage) => stage.stage === "validated");
    if (claimedComplete && implemented?.required !== false && implemented?.status !== "proved") {
      violations.push(violation("COMPLETION_WITHOUT_PROOF", item.id, `${item.task_id} is claimed complete without implemented proof`, "critical", [task.source_id]));
      violations.push(violation("COMPLETION_CONFLICT", item.id, `${item.task_id} completion claim conflicts with its proof record`, "critical", [task.source_id]));
    } else if (claimedComplete && validated?.required === true && validated.status !== "proved") {
      violations.push(violation("COMPLETION_WITHOUT_PROOF", item.id, `${item.task_id} is claimed complete without validation proof`, "critical", [task.source_id]));
    }
    let gap = false;
    for (let index = 1; index < outcome.stages.length; index += 1) {
      if (outcome.stages[index].status === "proved" && outcome.stages.slice(0, index).some((stage) => stage.required === true && stage.status !== "proved")) gap = true;
    }
    if (gap) violations.push(violation("OUTCOME_STAGE_GAP", item.id, `${item.task_id} has later-stage proof with an unproved prerequisite`, "high", [task.source_id]));
  }

  const workItemByTask = new Map(workItems.map((item) => [item.task_id, item]));
  for (const task of tasks) {
    if (task.backlog?.state !== "in_flight" && task.current_state.state !== "working") continue;
    if (!task.worktree || !task.worktree_present) violations.push(violation("ORPHANED_TASK", task.id, `${task.task_id} is active without a present registered worktree`, "critical", [task.source_id]));
    if (task.endpoint?.status === "absent") violations.push(violation("CUSTODY_CONFLICT", task.id, `${task.task_id} is active but its runtime endpoint is absent`, "critical", [task.source_id]));
    if (task.current_state.freshness === "stale") violations.push(violation("CUSTODY_STALE", task.id, `${task.task_id} custody evidence is stale`, "high", [task.source_id]));
  }
  for (const worktree of worktrees) {
    if (worktree.registered || worktree.bare) continue;
    violations.push(violation("UNREGISTERED_WORKTREE", worktree.id, `${worktree.path} is observable in scope but has no task or source registration`, "high", [worktree.source_id]));
  }
  for (const session of sessions) {
    if (!session.registered) violations.push(violation("UNREGISTERED_SESSION", session.id, `${session.provider} session ${session.session_id} is observable in scope but not registered`, "high", session.source_ids));
    if (session.project_source_id && !projectsBySource.has(session.project_source_id)) violations.push(violation("SESSION_PROJECT_UNRESOLVED", session.id, `${session.provider} session references an unregistered project source`, "critical", session.source_ids));
    if (session.work_item_id && !workItemByTask.has(session.work_item_id)) violations.push(violation("SESSION_WORK_ITEM_UNRESOLVED", session.id, `${session.provider} session references an unknown work item`, "critical", session.source_ids));
    const project = projectsBySource.get(session.project_source_id || "");
    if (project) {
      const positionEpoch = epochOf(project.continuity.position.observed_at);
      const handoffEpoch = epochOf(project.continuity.handoff.observed_at);
      if (positionEpoch !== null && session.observed_epoch > positionEpoch) violations.push(violation("TRANSCRIPT_NEWER_THAN_POSITION", session.id, `${session.provider} transcript is newer than ${project.name} Position state`, "high", [...session.source_ids, project.source_id]));
      if (handoffEpoch !== null && session.observed_epoch > handoffEpoch) violations.push(violation("TRANSCRIPT_NEWER_THAN_HANDOFF", session.id, `${session.provider} transcript is newer than ${project.name} handoff state`, "high", [...session.source_ids, project.source_id]));
    }
    const linked = session.work_item_id ? workItemByTask.get(session.work_item_id) : null;
    if (session.runtime.state === "idle" && linked && hasIncompleteRequiredStages(linked.outcome) && linked.backlog_state !== "done") violations.push(violation("SESSION_IDLE_INCOMPLETE", session.id, `${session.provider} session is idle while ${linked.task_id} remains incomplete`, "high", session.source_ids));
  }
  for (const source of sourceRecords) {
    if (source.status === "unavailable") violations.push(violation("SOURCE_UNAVAILABLE", `source:${source.id}`, `${source.id} is unavailable`, "critical", [source.id]));
    if (source.status === "stale") violations.push(violation("SOURCE_STALE", `source:${source.id}`, `${source.id} exceeds its freshness expectation`, "high", [source.id]));
  }

  for (const project of projects) observations.push({ id: `observation:${sha(`${project.id}\0git`).slice(0, 24)}`, subject_id: project.id, fact: "git_project_observed", value: true, source_id: project.source_id, pointer: project.path, observed_at: project.observed_at, freshness: "fresh", classification: "proved" });
  for (const task of tasks) observations.push({ id: `observation:${sha(`${task.id}\0state`).slice(0, 24)}`, subject_id: task.id, fact: "current_state", value: task.current_state.state, source_id: task.source_id, pointer: `${task.fm_home}/state/${task.task_id}.meta`, observed_at: task.current_state.observed_at, freshness: task.current_state.freshness, classification: task.current_state.classification });
  for (const session of sessions) observations.push({ id: `observation:${sha(`${session.id}\0transcript`).slice(0, 24)}`, subject_id: session.id, fact: "native_transcript_observed", value: { provider: session.provider, session_id: session.session_id, cwd: session.cwd }, source_id: session.source_ids[0], pointer: session.path, observed_at: session.observed_at, freshness: "observed", classification: "proved" });
  for (const item of workItems) {
    const itemViolations = violations.filter((entry) => entry.subject_id === item.id).map((entry) => entry.code);
    let custodyClassification = item.current_state.classification;
    if (itemViolations.some((code) => code === "CUSTODY_CONFLICT" || code === "COMPLETION_CONFLICT")) custodyClassification = "conflicting";
    else if (itemViolations.some((code) => code === "CUSTODY_STALE" || code === "WORK_ITEM_CONTROL_STALE")) custodyClassification = "stale";
    judgments.push({ id: `judgment:${sha(`${item.id}\0custody`).slice(0, 24)}`, subject_id: item.id, kind: "custody_state", state: item.current_state.state, classification: custodyClassification, source_ids: [taskByItemId.get(item.task_id)?.source_id].filter(Boolean), observed_at: nowIso, freshness: custodyClassification === "stale" ? "stale" : "fresh" });
    judgments.push({ id: `judgment:${sha(`${item.id}\0outcome`).slice(0, 24)}`, subject_id: item.id, kind: "outcome_stage", state: item.outcome.furthest_proved_stage, classification: item.outcome.furthest_proved_stage === "active" ? "unknown" : "proved", source_ids: [taskByItemId.get(item.task_id)?.source_id].filter(Boolean), observed_at: nowIso, freshness: "fresh" });
  }

  const captain = [];
  const supervisor = [];
  const externalWaits = [];
  const noProof = [];
  for (const item of workItems) {
    for (const decision of item.decisions || []) captain.push(attentionEntry("captain", item.id, item.title, "critical", decision.summary || decision.verb || "decision required", null, "captain"));
    if (["blocked", "parked"].includes(item.current_state.state)) supervisor.push(attentionEntry("supervisor", item.id, item.title, "high", `current state is ${item.current_state.state}`, "observe.reconcile", item.authority?.level || null));
    if (item.current_state.state === "paused") externalWaits.push(attentionEntry("external_wait", item.id, item.title, "medium", item.current_state.detail || "declared external wait", null, item.authority?.level || null));
    if (item.next_action && ["observe", "worker", "routine"].includes(item.authority?.level) && item.decisions.length === 0 && !["blocked", "parked", "paused"].includes(item.current_state.state)) supervisor.push(attentionEntry("safe_next", item.id, item.title, "medium", item.next_action.description, item.next_action.capability, item.authority.level));
    const missing = item.outcome.stages.filter((stage) => stage.required === true && stage.status !== "proved");
    if (missing.length > 0) noProof.push(attentionEntry("no_proof", item.id, item.title, missing.some((stage) => stage.status === "stale") ? "high" : "medium", `no current proof for ${missing.map((stage) => stage.stage).join(", ")}`, "observe.proof", item.authority?.level || null));
  }
  for (const item of violations) {
    const entry = attentionEntry("invariant", item.subject_id, item.code, item.severity, item.message, "observe.reconcile", item.code.includes("AUTHORITY") || item.code.includes("COMPLETION") ? "captain" : "supervisor");
    if (entry.authority === "captain") captain.push(entry);
    else supervisor.push(entry);
  }
  const dedupe = (items) => [...new Map(items.map((item) => [item.id, item])).values()].sort((a, b) => (SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity]) || a.id.localeCompare(b.id));
  const captainQueue = dedupe(captain);
  const supervisorQueue = dedupe(supervisor);
  const externalQueue = dedupe(externalWaits);
  const noProofQueue = dedupe(noProof);
  const allAttention = dedupe([...captainQueue, ...supervisorQueue, ...externalQueue, ...noProofQueue]);
  const fingerprintBasis = allAttention.map((item) => `${item.id}:${item.severity}`).sort();
  const attentionFingerprint = fingerprintBasis.length ? sha(JSON.stringify(fingerprintBasis)) : "none";
  const highestSeverity = allAttention[0]?.severity || "none";
  const progressing = workItems.filter((item) => item.current_state.state === "working").map((item) => attentionEntry("progress", item.id, item.title, "low", `${item.current_state.source} proves current work`, null, item.authority?.level || null));
  const stuck = dedupe([...supervisorQueue.filter((item) => item.kind === "supervisor"), ...externalQueue]);
  const safeNext = supervisorQueue.filter((item) => item.kind === "safe_next");
  const matters = dedupe([...captainQueue, ...supervisorQueue.filter((item) => ["critical", "high"].includes(item.severity)), ...externalQueue]).slice(0, 20);

  const capabilities = Array.isArray(registry.capabilities) ? registry.capabilities : [];
  const connectors = Array.isArray(registry.connectors) ? registry.connectors.map((connector) => ({
    id: connector.id,
    kind: connector.kind,
    status: connector.status || "unregistered",
    trust_domain: connector.trust_domain || null,
    capabilities: connector.capabilities || [],
    reason: connector.reason ? redactText(connector.reason) : null,
  })) : [];
  const sortedViolations = [...new Map(violations.map((item) => [item.id, item])).values()].sort((a, b) => (SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity]) || a.id.localeCompare(b.id));
  const result = {
    schema: OUTPUT_SCHEMA,
    generated: nowIso,
    scope: { id: registry.scope.id, description: redactText(registry.scope.description || ""), trust_domain: registry.scope.trust_domain || "software" },
    guarantee: {
      deterministic_over_registered_observable_sources: true,
      unobserved_external_reality: "unknown",
      completion_requires_evidence: true,
      transcript_content_retained: false,
    },
    source_registry: { path: realSafe(args.sources), schema: registry.schema, sources: sourceRecords.sort((a, b) => a.id.localeCompare(b.id)), connectors, capabilities },
    inventory: { projects, worktrees: worktrees.sort((a, b) => a.id.localeCompare(b.id)), tasks: tasks.sort((a, b) => a.id.localeCompare(b.id)), sessions },
    observations,
    judgments,
    work_items: workItems,
    invariants: { status: sortedViolations.length ? "violated" : "satisfied", violations: sortedViolations },
    attention: { fingerprint: attentionFingerprint, count: allAttention.length, highest_severity: highestSeverity, captain: captainQueue, supervisor: supervisorQueue, external_waits: externalQueue, no_proof: noProofQueue },
    orientation: { what_matters_now: matters, progressing: dedupe(progressing), stuck, needs_captain: captainQueue, safe_next: safeNext, no_proof: noProofQueue },
  };

  if (args.output === "json") process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else if (args.output === "fingerprint") process.stdout.write(`${result.attention.fingerprint}\t${result.attention.count}\t${result.attention.highest_severity}\n`);
  else process.stdout.write(renderHuman(result));
}

main().catch((error) => fail(redactText(error.message), 1));
