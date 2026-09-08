#!/usr/bin/env node
// fm-graph-server.mjs - the local live graph board for this firstmate home.
//
// A read-side projection over the records already on disk, served same-origin so
// the page can fetch and stream. It owns no ledger: every number it shows comes
// from an existing owner, and every action it offers is that owner's own command
// run with an argument vector.
//
//   projection   bin/fm-pipeline.sh board-json [--task <id>]   graph, nodes, edges, step
//                bin/fm-fleet-snapshot.sh --json               agent state, decisions, PR
//                state/<id>.busy-state                         current activity cell
//                state/<id>.status                             durable narrative
//   search       bin/fm-search.sh
//   control      bin/fm-control.sh <id> interrupt|exit
//   steer        bin/fm-send.sh <id> <text>
//   ask          bin/fm-inbox.sh note <text>
//
// Live updates are SSE. The whole board is projected once at boot; after that a
// filesystem watch invalidates ONE lane and reprojects only that lane, because
// the whole-board scan is an 18 second command and cannot be the live path.
//
// Nothing here runs on a timer. The fleet-wide agent read is expensive, so it
// happens when a reader asks for the board AND the watch has seen a record that
// read actually depends on move since the last one; an idle server with nobody
// looking does no work, and neither does one whose home is only writing records
// the fleet read is not a function of.
//
// Usage:
//   fm-graph-server.mjs [--port <n>] [--open]
//
// Environment:
//   FM_HOME              operational home (default: this repo)
//   FM_STATE_OVERRIDE    state directory for tests
//   FM_GRAPH_PORT        default port (default 7777)
//
// It binds 127.0.0.1 and nothing else, never interpolates a request field into a
// shell string, and never opens a filesystem path a request supplied: a task id
// from a request is matched against the ids this home actually has.
// No part of this server calls a model. The only judgement in the picture is
// firstmate answering a question this server delivered through fm-inbox.sh.

import { execFile } from "node:child_process";
import http from "node:http";
import { existsSync, readFileSync, watch } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..");
const FM_HOME = process.env.FM_HOME || ROOT;
const STATE = process.env.FM_STATE_OVERRIDE || join(FM_HOME, "state");
const HOST = "127.0.0.1";
const WATCH_DEBOUNCE_MS = 150;
const COMMAND_TIMEOUT_MS = 60000;
const FORGE_TIMEOUT_MS = 25000;
const SEARCH_TIMEOUT_MS = 20000;
const STATUS_MAX_LINES = 2000;
const CREW_STATE_TIMEOUT_MS = 20000;

// Only these steps have a writer anywhere in bin/ (bin/fm-pipeline.sh
// pipeline_step_known). Every other node on a lane is not "waiting", it is
// uninstrumented, and rendering the two the same way is the exact confusion
// this board exists to remove.
const INSTRUMENTED_STEPS = new Set(["dispatched", "pr-registered", "merged"]);

// The complete set of operations this server may perform on the fleet. Anything
// not on this table does not exist: there is no generic command route, and the
// argument vector is built here, never assembled from request text.
const ACTIONS = {
  interrupt: { bin: "fm-control.sh", argv: (id) => [id, "interrupt"], needsText: false },
  exit: { bin: "fm-control.sh", argv: (id) => [id, "exit"], needsText: false },
  steer: { bin: "fm-send.sh", argv: (id, text) => [id, text], needsText: true },
};

const PAGE_PATH = process.env.FM_GRAPH_PAGE
  || join(ROOT, ".agents", "skills", "graph-board", "assets", "graph-server-page.html");
let PAGE;
try {
  PAGE = readFileSync(PAGE_PATH, "utf8");
} catch {
  process.stderr.write(`fm-graph-server: the board page is missing: ${PAGE_PATH}\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let port = Number.parseInt(process.env.FM_GRAPH_PORT || "7777", 10);
let printReady = false;
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === "--port") {
    port = Number.parseInt(args[i + 1] || "", 10);
    i += 1;
  } else if (args[i] === "--ready-line") {
    printReady = true;
  } else if (args[i] === "--help" || args[i] === "-h") {
    process.stdout.write(usage());
    process.exit(0);
  } else {
    process.stderr.write(`fm-graph-server: unknown argument: ${args[i]}\n`);
    process.exit(2);
  }
}
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  process.stderr.write("fm-graph-server: --port must be a port number\n");
  process.exit(2);
}

function usage() {
  return [
    "fm-graph-server.mjs - local live graph board for this firstmate home",
    "",
    "  fm-graph-server.mjs [--port <n>] [--ready-line]",
    "",
    "Binds 127.0.0.1 only. Reads records through their existing owners and acts",
    "only through bin/fm-control.sh and bin/fm-send.sh.",
    "",
  ].join("\n");
}

// --- shelling out to the owners ---------------------------------------------

function ownerBin(name) {
  return join(ROOT, "bin", name);
}

// Every child is spawned with an argument vector and no shell, so no request
// field can ever become a command. The environment carries this home forward so
// the owners read the same records this projection does.
function runOwner(command, argv, timeout = COMMAND_TIMEOUT_MS) {
  return new Promise((resolvePromise) => {
    execFile(
      command,
      argv,
      {
        cwd: FM_HOME,
        timeout,
        maxBuffer: 64 * 1024 * 1024,
        env: { ...process.env, FM_HOME, FM_STATE_OVERRIDE: STATE },
      },
      (error, stdout, stderr) => {
        resolvePromise({
          ok: !error,
          code: error?.code ?? 0,
          stdout: stdout || "",
          stderr: stderr || "",
          error: error ? String(error.message || error) : null,
        });
      },
    );
  });
}

async function runOwnerJson(command, argv, timeout = COMMAND_TIMEOUT_MS) {
  const result = await runOwner(command, argv, timeout);
  if (!result.ok) return { ok: false, reason: result.stderr.trim() || result.error };
  try {
    return { ok: true, value: JSON.parse(result.stdout) };
  } catch (parseError) {
    return { ok: false, reason: `unreadable output: ${String(parseError.message || parseError)}` };
  }
}

// --- reading the records directly -------------------------------------------

// A task id reaches this server only from a request, so it is checked against
// the same shape the shell owners accept before it is ever used to build a path.
function safeTaskId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128
    && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value) && !value.includes("..");
}

function readTextFile(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function statePath(id, suffix) {
  return join(STATE, `${id}.${suffix}`);
}

// What an agent is doing is owned by bin/fm-crew-state.sh, not by this file.
// Reading state/<id>.busy-state here instead would be a second implementation
// of that contract, and it would get the two cases below wrong the way a
// hand-rolled read always does: the launch brief the spawner seeds classifies
// busy, and a harness that writes no record at all is not idle.
//
//   state: <verb> · source: <source> · <detail>
//
// The detail's parenthesised token is the busy classifier's own provenance, and
// "fm-spawn" is only ever the launch-brief seed (bin/fm-busy-lib.sh), so it
// means armed and not yet observed working.
function parseCrewState(line) {
  const match = /^state:\s*(\S+)\s*·\s*source:\s*(\S+)\s*·\s*(.*)$/.exec((line || "").trim());
  if (!match) return null;
  const detail = match[3].trim();
  const provenance = /\(([^)\s]+)[^)]*\)\s*$/.exec(detail);
  return { state: match[1], source: match[2], detail, provenance: provenance ? provenance[1] : null };
}

async function crewState(id) {
  const result = await runOwner(ownerBin("fm-crew-state.sh"), [id], CREW_STATE_TIMEOUT_MS);
  return parseCrewState(result.stdout.split("\n")[0]);
}

// Line numbers are the file's own, because a record's evidence can point at one
// (state/<id>.status:5) and a slice anchored on a renumbered line would quietly
// show the wrong node's narrative. So the cap drops old lines and keeps numbers.
function readStatusLines(id) {
  const raw = readTextFile(statePath(id, "status"));
  if (!raw) return [];
  return raw.split("\n").map((text, index) => {
    const at = text.indexOf(":");
    const head = at > 0 ? text.slice(0, at) : "";
    const known = ["working", "done", "blocked", "paused", "failed", "needs-decision", "resolved"];
    return {
      line: index + 1,
      state: known.includes(head) ? head : null,
      text,
    };
  }).filter((row) => row.text.trim() !== "").slice(-STATUS_MAX_LINES);
}

// The record rows themselves are a durable, per-node log: each carries the
// revision, the timestamp of the transition, and the artifact that proved it.
function readPipelineRows(id) {
  const raw = readTextFile(statePath(id, "pipeline"));
  if (!raw) return [];
  const rows = [];
  for (const line of raw.split("\n")) {
    if (!line.startsWith("rev=")) continue;
    const fields = {};
    for (const token of line.split(/\s+/)) {
      const at = token.indexOf("=");
      if (at > 0) fields[token.slice(0, at)] = token.slice(at + 1);
    }
    rows.push({
      rev: Number.parseInt(fields.rev || "0", 10) || 0,
      ts: fields.ts || null,
      step: fields.step || null,
      evidence: fields.evidence || null,
      head: fields.head && fields.head !== "unknown" ? fields.head : null,
      attempt: fields.attempt && fields.attempt !== "-" ? fields.attempt : null,
      raw: line,
    });
  }
  return rows;
}

// --- the projection ----------------------------------------------------------

// Bumped by the filesystem watch, so "did anything move" is answered by the
// mechanism that already knows, not by a clock.
let stateRevision = 0;
let snapshotRevision = -1;
let snapshotInFlight = null;
let snapshotReads = 0;

const projection = {
  ready: false,
  boardAt: null,
  snapshotAt: null,
  boardError: null,
  snapshotError: null,
  lanes: new Map(),
  home: FM_HOME,
};

function snapshotRowFor(id) {
  return projection.snapshotById?.get(id) || null;
}

// Per-node state, derived here and nowhere else. Three distinctions matter and
// each is a different colour on the board: proven, genuinely not reached yet,
// and never instrumented at all.
function nodeStates(lane) {
  const nodes = lane.board?.steps?.nodes || [];
  const readable = lane.board?.record_state === "ok";
  const at = nodes.indexOf(lane.board?.step);
  const agent = lane.agent?.state || null;
  return nodes.map((name, index) => {
    if (!INSTRUMENTED_STEPS.has(name)) return { name, state: "uninstrumented" };
    if (!readable || at < 0) return { name, state: "unknown" };
    if (index < at) return { name, state: "done" };
    if (index > at) return { name, state: "pending" };
    if (agent === "blocked" || agent === "failed") return { name, state: "blocked" };
    if (name === "merged") return { name, state: "done" };
    return { name, state: "current" };
  });
}

// One line the captain can scan: what needs him, what is moving, what is stuck.
function laneAttention(lane) {
  if (lane.board?.record_state && lane.board.record_state !== "ok") return "record";
  if ((lane.agent?.open_decisions?.length || 0) > 0) return "needs-you";
  const state = lane.activity?.state || lane.agent?.state || null;
  if (state === "blocked" || state === "failed") return "needs-you";
  if (state === "done") return "landed";
  if (state === "paused") return "waiting";
  if (state === "working") {
    // Armed is its own answer. A seat that was handed a brief and has produced
    // no activity of its own is not running, and calling it running is how a
    // dead lane hides among the live ones.
    return lane.activity?.provenance === "fm-spawn" ? "armed" : "running";
  }
  // Unknown is stated, never folded into quiet: an instrument that cannot
  // answer has to say so.
  if (!state || state === "unknown") return "unknown";
  return "idle";
}

function laneView(lane) {
  return {
    id: lane.id,
    kind: lane.board?.kind || null,
    step: lane.board?.step || null,
    step_ts: lane.board?.step_ts || null,
    record_state: lane.board?.record_state || null,
    nodes: nodeStates(lane),
    edges: lane.board?.steps?.edges || [],
    agent: lane.agent,
    activity: lane.activity,
    pr: lane.pr,
    attention: laneAttention(lane),
    last_event: lane.lastEvent,
    updated_at: lane.updatedAt,
  };
}

function boardView() {
  return {
    schema: "fm-graph-server.v1",
    ready: projection.ready,
    home: projection.home,
    board_at: projection.boardAt,
    snapshot_at: projection.snapshotAt,
    board_error: projection.boardError,
    snapshot_error: projection.snapshotError,
    lanes: [...projection.lanes.values()].map(laneView).sort((a, b) => a.id.localeCompare(b.id)),
  };
}

function ensureLane(id) {
  let lane = projection.lanes.get(id);
  if (!lane) {
    lane = { id, board: null, agent: null, activity: null, pr: null, lastEvent: null, updatedAt: null };
    projection.lanes.set(id, lane);
  }
  return lane;
}

function applyLocalRecords(lane) {
  const lines = readStatusLines(lane.id);
  lane.lastEvent = lines.length > 0 ? lines[lines.length - 1] : null;
  lane.updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function applySnapshotRow(lane, row) {
  if (!row) return;
  // The snapshot's current_state is bin/fm-crew-state.sh's own line, so it
  // seeds the activity cell with the same verdict a live per-lane read gives.
  if (row.current_state?.raw) lane.activity = parseCrewState(row.current_state.raw) || lane.activity;
  lane.agent = {
    state: row.current_state?.state || null,
    source: row.current_state?.source || null,
    detail: row.current_state?.detail || null,
    open_decisions: row.hints?.open_decisions || [],
    harness: row.harness || null,
    model: row.model || null,
    project: row.project || null,
    mode: row.mode || null,
    endpoint: row.endpoint?.status || null,
  };
  lane.pr = row.pr?.url || null;
}

async function projectWholeBoard() {
  const result = await runOwnerJson(ownerBin("fm-pipeline.sh"), ["board-json"]);
  if (!result.ok) {
    projection.boardError = result.reason;
    return;
  }
  projection.boardError = null;
  const seen = new Set();
  for (const row of result.value.tasks || []) {
    seen.add(row.id);
    const lane = ensureLane(row.id);
    lane.board = row;
    applyLocalRecords(lane);
  }
  for (const id of [...projection.lanes.keys()]) {
    if (!seen.has(id)) projection.lanes.delete(id);
  }
  projection.boardAt = new Date(result.value.generated_epoch * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

async function projectOneLane(id) {
  const result = await runOwnerJson(ownerBin("fm-pipeline.sh"), ["board-json", "--task", id]);
  if (!result.ok) return null;
  const row = (result.value.tasks || [])[0] || null;
  if (!row) {
    if (projection.lanes.delete(id)) return { id, removed: true };
    return null;
  }
  const lane = ensureLane(id);
  lane.board = row;
  applyLocalRecords(lane);
  applySnapshotRow(lane, snapshotRowFor(id));
  // One lane, one owner call: this is what keeps the activity cell live between
  // the slow whole-fleet reads without ever computing the verdict here.
  lane.activity = (await crewState(id)) || lane.activity;
  return laneView(lane);
}

// The one entry point for the fleet-wide read. It is a no-op unless a reader is
// asking and the records have moved since the last read, and it never runs two
// at once, so repeated asks against an unchanged home cost nothing.
function refreshSnapshotOnDemand() {
  if (snapshotInFlight) return snapshotInFlight;
  if (snapshotRevision === stateRevision && projection.snapshotAt) return null;
  const wanted = stateRevision;
  snapshotInFlight = refreshSnapshot()
    .then(() => {
      snapshotRevision = wanted;
      publish("board", boardView());
    })
    .finally(() => {
      snapshotInFlight = null;
    });
  return snapshotInFlight;
}

async function refreshSnapshot() {
  snapshotReads += 1;
  const result = await runOwnerJson(ownerBin("fm-fleet-snapshot.sh"), ["--json"]);
  if (!result.ok) {
    projection.snapshotError = result.reason;
    return;
  }
  projection.snapshotError = null;
  projection.snapshotById = new Map((result.value.tasks || []).map((row) => [row.id, row]));
  projection.backlog = result.value.backlog?.records || [];
  for (const lane of projection.lanes.values()) applySnapshotRow(lane, snapshotRowFor(lane.id));
  projection.snapshotAt = result.value.generated || null;
}

// --- SSE fan-out -------------------------------------------------------------

const clients = new Set();

function publish(event, data) {
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const client of clients) {
    try {
      client.write(frame);
    } catch {
      clients.delete(client);
    }
  }
}

// --- per-node logs -----------------------------------------------------------

// Node logs are resolved, never invented. A node with no durable source says so
// and names why, because a button that opens nothing is worse than no button.
function statusSliceFor(id, rows, index) {
  const anchor = (row) => {
    const match = /(?:^|:)state\/[^:]+\.status:(\d+)$/.exec(row?.evidence || "");
    return match ? Number.parseInt(match[1], 10) : null;
  };
  const from = anchor(rows[index]);
  if (from === null) return null;
  let to = Infinity;
  for (let i = index + 1; i < rows.length; i += 1) {
    const next = anchor(rows[i]);
    if (next !== null) {
      to = next;
      break;
    }
  }
  const lines = readStatusLines(id).filter((row) => row.line >= from && row.line < to);
  return lines.length > 0 ? lines : null;
}

async function resolveNodeLog(id, step) {
  const lane = projection.lanes.get(id);
  const rows = readPipelineRows(id);
  const index = rows.findIndex((row) => row.step === step);

  if (index >= 0) {
    const slice = statusSliceFor(id, rows, index);
    const record = rows[index];
    return {
      task: id,
      step,
      source: slice ? "record+status-slice" : "record",
      entries: [
        { kind: "record", ts: record.ts, text: record.raw },
        ...(slice || []).map((row) => ({ kind: "status", ts: null, text: row.text })),
      ],
      note: slice
        ? null
        : "This node's durable source is its own transition record. The task narrative below covers the work itself.",
    };
  }

  // The review nodes describe our own pull request, and that already has a
  // reader in bin/. Nothing else here reaches the network.
  if (lane?.pr && (step === "pr-registered" || step === "checks" || step === "merge-wait")) {
    const forge = await forgeLog(lane.pr, step);
    if (forge) return { task: id, step, ...forge };
  }

  return {
    task: id,
    step,
    source: "none",
    entries: [],
    note: !INSTRUMENTED_STEPS.has(step)
      ? `No writer records "${step}" yet, so this node has no durable log. It is uninstrumented, not stalled.`
      : `Nothing has recorded "${step}" for this task yet.`,
  };
}

function parsePrUrl(url) {
  const match = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(url || "");
  return match ? { repo: `${match[1]}/${match[2]}`, number: match[3] } : null;
}

async function forgeLog(url, step) {
  const pr = parsePrUrl(url);
  if (!pr) return null;
  const argv = step === "pr-registered"
    ? ["pr", "view", pr.number, "-R", pr.repo, "--reviews"]
    : ["pr", "checks", pr.number, "-R", pr.repo];
  const result = await runOwner("gh-axi", argv, FORGE_TIMEOUT_MS);
  const text = (result.ok ? result.stdout : result.stderr).trim();
  if (!text) return null;
  return {
    source: "forge",
    entries: text.split("\n").map((line) => ({ kind: "forge", ts: null, text: line })),
    note: result.ok ? null : "The forge read failed; this is its error, not the node's log.",
  };
}

// --- routes ------------------------------------------------------------------

function send(response, status, body, type = "application/json") {
  const payload = type === "application/json" ? JSON.stringify(body) : body;
  response.writeHead(status, {
    "content-type": type === "application/json" ? "application/json; charset=utf-8" : type,
    "cache-control": "no-store",
  });
  response.end(payload);
}

function readBody(request) {
  return new Promise((resolvePromise, rejectPromise) => {
    let size = 0;
    const chunks = [];
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > 64 * 1024) {
        rejectPromise(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        resolvePromise(text ? JSON.parse(text) : {});
      } catch (error) {
        rejectPromise(error);
      }
    });
    request.on("error", rejectPromise);
  });
}

// --- request origin ----------------------------------------------------------

// This server binds loopback, which is not by itself an access boundary: any
// page the operator merely visits can send a "simple" cross-origin POST, and
// text/plain carrying JSON is simple, so it needs no preflight and arrives
// without this server ever being consulted. Two checks close that.
//
// Host is asserted on EVERY route, not only the mutating ones. A name in a
// foreign domain that resolves to 127.0.0.1 (DNS rebinding) makes an attacker's
// page same-origin with this one, and from there it could read this home's
// records; only the Host header still names the attacker's domain.
let boundPort = null;

// "localhost" is accepted alongside the bound address because RFC 6761 requires
// it to resolve to loopback, so it cannot be pointed at an attacker the way an
// ordinary name can - and refusing it would 403 an operator who simply typed
// localhost instead of the address this server prints.
function loopbackNames() {
  return [HOST, "localhost"];
}

function hostIsThisServer(request) {
  const host = request.headers.host;
  if (!host) return false;
  return loopbackNames().some((name) => host === `${name}:${boundPort}` || host === name);
}

// An absent Origin is accepted because a same-origin GET and a curl both omit
// it; what must never be accepted is an Origin naming somewhere else.
function originIsThisServer(request) {
  const origin = request.headers.origin;
  if (origin === undefined) return true;
  return loopbackNames().some((name) => origin === `http://${name}:${boundPort}`);
}

// Declared JSON is required on mutating routes precisely because it is what a
// cross-origin form or simple fetch cannot set without a preflight this server
// never answers.
function bodyDeclaresJson(request) {
  const type = request.headers["content-type"] || "";
  return type.split(";")[0].trim().toLowerCase() === "application/json";
}

const routes = [
  ["GET", "/", (request, response) => send(response, 200, PAGE, "text/html; charset=utf-8")],
  ["GET", "/health", (request, response) => send(response, 200, {
    ok: true,
    ready: projection.ready,
    lanes: projection.lanes.size,
    // Liveness only, so this route deliberately does NOT trigger a read; it
    // reports whether one has happened, and how many have.
    agent_state_read: projection.snapshotAt !== null || projection.snapshotError !== null,
    agent_state_reads: snapshotReads,
  })],
  ["GET", "/api/board", (request, response) => {
    // Fire and forget: a reader gets what is projected now, and the fleet read
    // it triggered arrives on the stream when it finishes.
    refreshSnapshotOnDemand();
    send(response, 200, boardView());
  }],
  ["GET", "/events", handleEvents],
  ["GET", "/api/log", handleLog],
  ["GET", "/api/status", handleStatus],
  ["GET", "/api/search", handleSearch],
  ["GET", "/api/chat", handleChatRead],
  ["POST", "/api/action", handleAction],
  ["POST", "/api/ask", handleAsk],
];

function handleEvents(request, response) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-store",
    connection: "keep-alive",
  });
  response.write(`event: board\ndata: ${JSON.stringify(boardView())}\n\n`);
  clients.add(response);
  refreshSnapshotOnDemand();
  const beat = setInterval(() => {
    try {
      response.write(": beat\n\n");
    } catch {
      clearInterval(beat);
    }
  }, 25000);
  request.on("close", () => {
    clearInterval(beat);
    clients.delete(response);
  });
}

async function handleLog(request, response, url) {
  const task = url.searchParams.get("task") || "";
  const step = url.searchParams.get("step") || "";
  if (!safeTaskId(task) || !projection.lanes.has(task)) return send(response, 404, { error: "unknown task" });
  if (!/^[a-z-]{1,32}$/.test(step)) return send(response, 400, { error: "unknown step" });
  send(response, 200, await resolveNodeLog(task, step));
}

function handleStatus(request, response, url) {
  const task = url.searchParams.get("task") || "";
  if (!safeTaskId(task) || !projection.lanes.has(task)) return send(response, 404, { error: "unknown task" });
  const lane = projection.lanes.get(task);
  send(response, 200, {
    task,
    lines: readStatusLines(task),
    records: readPipelineRows(task),
    busy: lane.busy,
    agent: lane.agent,
    pr: lane.pr,
  });
}

async function handleSearch(request, response, url) {
  const query = url.searchParams.get("q") || "";
  if (query.length < 2 || query.length > 200) return send(response, 400, { error: "query must be 2-200 characters" });
  // Delegated whole: this server never walks state/ itself, because the search
  // owner is what keeps credential-bearing paths out of the results.
  const result = await runOwner(ownerBin("fm-search.sh"), ["--fixed-strings", "--line-number", "--max-count", "4", "--", query], SEARCH_TIMEOUT_MS);
  const hits = (result.stdout || "").split("\n").filter(Boolean).slice(0, 300).map((line) => {
    const match = /^([^:]+):(\d+):(.*)$/.exec(line);
    return match ? { path: match[1], line: Number.parseInt(match[2], 10), text: match[3].slice(0, 400) } : { path: null, line: null, text: line.slice(0, 400) };
  });
  send(response, 200, { query, hits, truncated: hits.length >= 300, error: result.code === 2 ? result.stderr.trim() : null });
}

async function handleChatRead(request, response) {
  const result = await runOwner(ownerBin("fm-inbox.sh"), ["list"]);
  send(response, 200, { ok: result.ok, text: result.stdout.trim() || result.stderr.trim() });
}

async function handleAction(request, response) {
  let body;
  try {
    body = await readBody(request);
  } catch {
    return send(response, 400, { error: "unreadable request body" });
  }
  const action = ACTIONS[body.action];
  if (!action) return send(response, 400, { error: "unknown action" });
  const task = body.task;
  if (!safeTaskId(task) || !projection.lanes.has(task)) return send(response, 404, { error: "unknown task" });
  let text = null;
  if (action.needsText) {
    text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text || text.length > 4000) return send(response, 400, { error: "text must be 1-4000 characters" });
  }
  const argv = action.argv(task, text);
  const command = ownerBin(action.bin);
  const result = await runOwner(command, argv);
  // Every action names what was invoked and by which owner, on the server's own
  // log and in the response, so an operator can always tell what the board did.
  const invoked = `${command} ${argv.map((value) => JSON.stringify(value)).join(" ")}`;
  process.stderr.write(`fm-graph-server: action ${body.action} -> ${invoked} exit=${result.ok ? 0 : result.code}\n`);
  send(response, result.ok ? 200 : 502, {
    ok: result.ok,
    action: body.action,
    invoked,
    output: (result.stdout + result.stderr).trim().slice(0, 8000),
  });
}

async function handleAsk(request, response) {
  let body;
  try {
    body = await readBody(request);
  } catch {
    return send(response, 400, { error: "unreadable request body" });
  }
  const question = typeof body.question === "string" ? body.question.trim() : "";
  if (!question || question.length > 4000) return send(response, 400, { error: "question must be 1-4000 characters" });
  const task = typeof body.task === "string" && safeTaskId(body.task) && projection.lanes.has(body.task) ? body.task : null;
  const text = task ? `[graph board] ${task}: ${question}` : `[graph board] ${question}`;
  // The captain's note surface is the existing wake path into firstmate. This
  // server does not answer, and nothing here calls a model.
  const result = await runOwner(ownerBin("fm-inbox.sh"), ["note", text]);
  send(response, result.ok ? 200 : 502, {
    ok: result.ok,
    delivered: result.ok,
    output: (result.stdout + result.stderr).trim().slice(0, 4000),
  });
}

// --- watching state/ ---------------------------------------------------------

// Records a lane's own projection is a function of. A change here reprojects
// that one lane and nothing else.
const WATCHED_SUFFIXES = new Set(["pipeline", "meta", "status", "busy-state"]);

// Records the FLEET-WIDE read is a function of, which is a strictly smaller set
// and deliberately so: that read costs tens of seconds, so it may only be
// invalidated by a record it actually depends on.
//
//   meta         the task inventory and its scalar facts
//   status       open decisions and the recorded pull request
//   busy-state   what the agent is doing
//
// A pipeline record is absent on purpose. It moves the graph, and the
// single-lane reprojection above already covers that, so dragging the whole
// fleet read along with it would be the coarse invalidation this list exists to
// prevent. Everything else under state/ - the wake queue, event logs, turn-end
// and trust markers, board scratch files - invalidates nothing at all.
const FLEET_SUFFIXES = new Set(["meta", "status", "busy-state"]);

const pendingIds = new Set();
let flushTimer = null;

function onStateChange(filename) {
  if (!filename) return;
  const at = filename.indexOf(".");
  if (at <= 0) return;
  const id = filename.slice(0, at);
  const suffix = filename.slice(at + 1);
  if (!safeTaskId(id)) return;
  if (FLEET_SUFFIXES.has(suffix)) stateRevision += 1;
  if (!WATCHED_SUFFIXES.has(suffix)) return;
  pendingIds.add(id);
  if (flushTimer) return;
  flushTimer = setTimeout(flushPending, WATCH_DEBOUNCE_MS);
}

async function flushPending() {
  flushTimer = null;
  const ids = [...pendingIds];
  pendingIds.clear();
  for (const id of ids) {
    const view = await projectOneLane(id);
    if (view) publish("lane", view);
  }
}

// --- boot --------------------------------------------------------------------

const server = http.createServer(async (request, response) => {
  let url;
  try {
    url = new URL(request.url || "/", `http://${HOST}`);
  } catch {
    return send(response, 400, { error: "bad request" });
  }
  if (!hostIsThisServer(request) || !originIsThisServer(request)) {
    return send(response, 403, { error: "forbidden" });
  }
  const route = routes.find(([method, path]) => method === request.method && path === url.pathname);
  if (!route) return send(response, 404, { error: "not found" });
  if (route[0] !== "GET" && !bodyDeclaresJson(request)) {
    return send(response, 403, { error: "forbidden" });
  }
  try {
    await route[2](request, response, url);
  } catch (error) {
    if (!response.headersSent) send(response, 500, { error: String(error.message || error) });
  }
});

server.listen(port, HOST, async () => {
  const actual = server.address().port;
  boundPort = actual;
  process.stderr.write(`fm-graph-server: http://${HOST}:${actual}  home=${FM_HOME}\n`);
  if (printReady) process.stdout.write(`ready http://${HOST}:${actual}\n`);

  await projectWholeBoard();
  projection.ready = true;
  publish("board", boardView());

  if (existsSync(STATE)) {
    try {
      watch(STATE, { persistent: true }, (_event, filename) => onStateChange(String(filename || "")));
    } catch (error) {
      process.stderr.write(`fm-graph-server: state watch unavailable: ${String(error.message || error)}\n`);
    }
  }
});

