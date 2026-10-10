#!/usr/bin/env node
// tests/t3-fake-server.mjs - a fake T3 Code server for the t3code backend
// suites (tests/fm-t3-mcp.test.sh, tests/fm-backend-t3code.test.sh).
//
// It serves T3's headless OAuth sign-in (/oauth/mcp/register, /decision,
// /token) and the Orchestrator V2 `/mcp` streamable-HTTP endpoint with the
// tool subset bin/fm-t3-mcp.mjs drives. Shapes follow T3 main 50647de0 and
// 0.0.46 nightly as recorded in docs/verification/runtime-backends.md,
// including the protocol facts a simpler fake would hide:
//   - t3_thread_list pages by cursor (default 50, at most 100) and reports
//     each thread's relationshipToParent (fork or subagent);
//   - t3_thread_read caps limit at 100;
//   - t3_thread_wait waits on the exact runId when given and on the latest
//     run by ordinal otherwise, blocking until that run is terminal or the
//     timeout passes;
//   - t3_thread_interrupt targets the latest active run and only requests
//     the stop: the run ends asynchronously, before the next call by default;
//   - archive is distinct from run end: the active run ends asynchronously;
//   - a send is committed before its reply, which dropReplyTools can lose;
//   - pendingRequestCount counts every pending runtime request, while the
//     t3_pending_request_* tools see only user-input questions.
//
// Usage: t3-fake-server.mjs --case-file <file> --port-file <file> [--parent-pid <pid>]
// <case-file> holds the path of the current case directory. Every request
// re-reads <case-dir>/world.json, writes it back after a mutation, and appends
// one JSON line to <case-dir>/requests.jsonl, so a test can switch cases and
// edit the world between calls. World keys (all optional):
//   tokens (accepted bearers; sign-in appends), environmentId, serverVersion,
//   tools (array of names; default all), revoked (every /mcp call is 401),
//   sse (SSE replies), expiresIn (seconds), bindWorktree, bindInstance,
//   bindRuntimeMode, bindModel, bindOptions (override what a launch binds),
//   archiveKeepsRun (archive never ends the run), interruptStuck or
//   waitTimesOut (an interrupt never ends the run), queueAfterInterrupt
//   (text a queued run starts with once an interrupt lands), failTools
//   ({name: {code, message}}), dropTools ({name: count}: close the connection
//   without a reply or effect that many times), dropReplyTools ({name:
//   count}: apply the call, then close without a reply), probePath (each log
//   line records whether it exists), providers (the orchestrator_capabilities
//   catalog; default FAKE_PROVIDERS), projects ([{id, title, workspaceRoot,
//   defaultModelSelection, deletedAt}]), threads ({id: detail plus items,
//   runs, and runtimeRequests [{id, kind: user_input|approval, status,
//   questions}]}).

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].slice(2)] = process.argv[i + 1];

const ALL_TOOLS = [
  "t3_thread_launch", "t3_thread_send", "t3_thread_read", "t3_thread_wait", "t3_thread_interrupt",
  "t3_thread_organize", "t3_thread_list", "t3_thread_configuration", "t3_project_list", "t3_project_create",
  "t3_pending_request_list", "t3_pending_request_read", "t3_pending_request_respond",
  "orchestrator_capabilities", "t3_environment_read",
];
const ACTIVE = new Set(["preparing", "queued", "starting", "running", "waiting"]);
const TERMINAL = new Set(["completed", "failed", "cancelled", "interrupted", "rolled_back"]);
const select = (id, values) => ({ id, label: id, type: "select", options: values.map((v) => ({ id: v, label: v })) });
const FAKE_PROVIDERS = [
  {
    providerInstanceId: "claudeAgent", driverKind: "claudeAgent", displayName: "Claude", constraints: [],
    models: ["claude-sonnet-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-5-5"].map((id) => ({
      id, label: id, options: [select("effort", ["low", "medium", "high", "xhigh", "max"]), { id: "fastMode", label: "Fast Mode", type: "boolean" }],
    })),
  },
  {
    providerInstanceId: "codex", driverKind: "codex", displayName: "Codex", constraints: [],
    models: ["gpt-5.6-sol", "gpt-6-luna"].map((id) => ({
      id, label: id, options: [select("reasoningEffort", ["low", "medium", "high", "xhigh"]), select("serviceTier", ["default", "priority"])],
    })),
  },
];

const caseDir = () => readFileSync(args["case-file"], "utf8").trim();
const worldFile = () => path.join(caseDir(), "world.json");
const loadWorld = () => {
  try {
    return JSON.parse(readFileSync(worldFile(), "utf8"));
  } catch {
    return {};
  }
};
const saveWorld = (w) => writeFileSync(worldFile(), JSON.stringify(w));
const log = (w, entry) => {
  if (w.probePath) entry.probe = existsSync(w.probePath);
  appendFileSync(path.join(caseDir(), "requests.jsonl"), `${JSON.stringify(entry)}\n`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const clients = new Map();
const codes = new Map();

function body(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
  });
}

function json(res, status, obj, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(obj));
}

const err = (code, message) => ({ isError: true, structuredContent: { error: { code, message } }, content: [{ type: "text", text: message }] });
const ok = (data) => ({ structuredContent: data, content: [{ type: "text", text: JSON.stringify(data) }] });
const now = () => new Date().toISOString();

const pendingRequests = (t) => (t.runtimeRequests ?? []).filter((r) => r.status === "pending");

function detail(t) {
  const { items, runs, runtimeRequests, modelSelection, ...rest } = t;
  if (runtimeRequests) rest.pendingRequestCount = pendingRequests(t).length;
  return rest;
}

// Runs newest first; a run without an ordinal ranks by its array position.
const byOrdinal = (t) => (t.runs ?? []).map((r, i, all) => ({ r, o: r.ordinal ?? all.length - i })).sort((a, b) => b.o - a.o).map((x) => x.r);
const latestRun = (t) => byOrdinal(t)[0];
const latestActiveRun = (t) => byOrdinal(t).find((r) => ACTIVE.has(r.status));

function refreshThread(t) {
  const active = latestActiveRun(t);
  t.activeRunId = active?.runId ?? null;
  t.status = active?.status ?? latestRun(t)?.status ?? "idle";
}

function startRun(t, text) {
  const runId = `run:${randomUUID()}`;
  t.runs = t.runs ?? [];
  const ordinal = Math.max(0, ...byOrdinal(t).map((r, i, all) => r.ordinal ?? all.length - i)) + 1;
  t.runs.unshift({ runId, ordinal, status: "running", requestedAt: now(), startedAt: now(), completedAt: null });
  t.activeRunId = runId;
  t.status = "running";
  t.latestRunId = runId;
  t.items = t.items ?? [];
  t.items.push({ type: "user_message", status: "completed", text });
  return runId;
}

function endRun(t, run, status) {
  run.status = status;
  run.completedAt = now();
  delete run.stopRequested;
  if ((t.runs ?? []).length > 0) refreshThread(t);
}

// The asynchronous provider effects of an earlier interrupt or archive land
// before the next call (or wait poll), unless the world holds them back.
function settle(w) {
  let changed = false;
  for (const t of Object.values(w.threads ?? {})) {
    for (const run of t.runs ?? []) {
      if (!run.stopRequested || !ACTIVE.has(run.status)) continue;
      if (run.stopRequested === "interrupt" && (w.interruptStuck || w.waitTimesOut)) continue;
      if (run.stopRequested === "archive" && w.archiveKeepsRun) continue;
      endRun(t, run, "interrupted");
      changed = true;
      if (run.queueAfterInterrupt) startRun(t, run.queueAfterInterrupt);
    }
  }
  return changed;
}

const notFound = (id) => err("thread_not_found", `Thread ${id} is no longer available.`);

function listItem(x) {
  return {
    threadId: x.threadId, title: x.title, status: x.status, latestRunId: x.latestRunId ?? null,
    parentThreadId: x.parentThreadId ?? null, relationshipToParent: x.relationshipToParent ?? null,
  };
}

// Returns [result, changed].
async function callTool(w, name, a) {
  const fail = (w.failTools ?? {})[name];
  if (fail) return [err(fail.code, fail.message), false];
  const threads = (w.threads = w.threads ?? {});
  const projects = (w.projects = w.projects ?? []);
  const t = a.threadId !== undefined ? threads[a.threadId] : undefined;
  switch (name) {
    case "t3_environment_read":
      return [ok({ environmentId: w.environmentId ?? "env-fake-1", serverVersion: w.serverVersion ?? "0.0.46-nightly.fake" }), false];
    case "orchestrator_capabilities":
      return [ok({ parentThreadId: null, runtimeMode: "full-access", interactionMode: "default", providers: w.providers ?? FAKE_PROVIDERS }), false];
    case "t3_project_list":
      return [ok({ projects, nextCursor: null }), false];
    case "t3_project_create": {
      if (projects.some((p) => !p.deletedAt && p.workspaceRoot === a.workspaceRoot)) return [err("invalid_request", "workspace already registered"), false];
      const p = { id: `mcp:proj-${randomUUID()}`, title: a.title, workspaceRoot: a.workspaceRoot, defaultModelSelection: null, deletedAt: null };
      projects.push(p);
      return [ok(p), true];
    }
    case "t3_thread_launch": {
      const ws = a.workspaceStrategy ?? {};
      const id = `mcp:${randomUUID()}`;
      const sel = a.modelSelection ?? {};
      const modelSelection = {
        instanceId: w.bindInstance ?? sel.instanceId,
        model: w.bindModel ?? sel.model,
        ...(w.bindOptions !== undefined ? { options: w.bindOptions } : sel.options !== undefined ? { options: sel.options } : {}),
      };
      const n = {
        threadId: id, projectId: a.projectId, title: a.title, status: "idle", latestRunId: null, activeRunId: null,
        providerInstanceId: modelSelection.instanceId, model: modelSelection.model, modelSelection,
        runtimeMode: w.bindRuntimeMode ?? a.runtimeMode, interactionMode: a.interactionMode,
        branch: ws.branch ?? null, worktreePath: w.bindWorktree ?? (ws.type === "existing_worktree" ? ws.worktreePath : null),
        parentThreadId: null, relationshipToParent: null, pendingRequestCount: 0, archived: false, items: [], runs: [],
      };
      threads[id] = n;
      if (a.message) startRun(n, a.message);
      return [ok({ threadId: id, projectId: n.projectId, runId: n.activeRunId, status: n.status }), true];
    }
    case "t3_thread_send": {
      if (!t) return [notFound(a.threadId), false];
      if (t.archived) return [err("thread_not_sendable", `Thread ${a.threadId} is archived and cannot receive messages.`), false];
      w.requestIds = w.requestIds ?? {};
      const key = `${a.threadId}|${a.clientRequestId}`;
      if (a.clientRequestId && w.requestIds[key]) return [ok(w.requestIds[key]), false];
      let delivery = "steered";
      if (t.activeRunId) t.items.push({ type: "user_message", status: "completed", text: a.message });
      else {
        startRun(t, a.message);
        delivery = "started";
      }
      const out = { threadId: t.threadId, messageId: `msg:${randomUUID()}`, runId: t.activeRunId, status: "running", delivery };
      if (a.clientRequestId) w.requestIds[key] = out;
      return [ok(out), true];
    }
    case "t3_thread_read": {
      if (!t) return [notFound(a.threadId), false];
      if ((a.limit ?? 0) > 100) return [err("invalid_request", "limit must be <= 100"), false];
      // T3 pages forward from afterPosition (exclusive), oldest first.
      const matching = (t.items ?? []).map((it, position) => ({ ...it, position })).filter((it) => it.position > (a.afterPosition ?? -1));
      const items = matching.slice(0, a.limit ?? 50);
      const thread = { ...detail(t), itemCount: (t.items ?? []).length };
      return [ok({ thread, recentRuns: byOrdinal(t).slice(0, a.runLimit ?? 5), items, nextPosition: items.at(-1)?.position ?? null, hasMore: matching.length > items.length }), false];
    }
    case "t3_thread_list": {
      if ((a.limit ?? 0) > 100) return [err("invalid_request", "limit must be <= 100"), false];
      const wanted = a.statuses ? new Set(a.statuses) : null;
      const list = Object.values(threads)
        .filter((x) => x.projectId === a.projectId && (!wanted || wanted.has(x.status)))
        .filter((x) => a.includeSubagents !== false || x.relationshipToParent !== "subagent");
      const cursor = a.cursor ?? 0;
      const page = list.slice(cursor, cursor + (a.limit ?? 50));
      const nextCursor = cursor + page.length < list.length ? cursor + page.length : null;
      return [ok({ projectId: a.projectId, currentThreadId: null, threads: page.map(listItem), nextCursor, total: list.length }), false];
    }
    case "t3_thread_configuration": {
      if (!t) return [notFound(a.threadId), false];
      const modelSelection = t.modelSelection ?? { instanceId: t.providerInstanceId, model: t.model };
      return [ok({ threadId: t.threadId, modelSelection, runtimeMode: t.runtimeMode, interactionMode: t.interactionMode ?? "default" }), false];
    }
    case "t3_thread_wait":
      return [await waitRun(a), false];
    case "t3_thread_interrupt": {
      if (!t) return [notFound(a.threadId), false];
      const explicit = a.runId === undefined ? undefined : (t.runs ?? []).find((r) => r.runId === a.runId);
      if (a.runId !== undefined && !explicit) return [err("run_not_found", `Run ${a.runId} is not in thread ${a.threadId}.`), false];
      if (explicit && TERMINAL.has(explicit.status)) return [ok({ threadId: t.threadId, runId: explicit.runId, status: explicit.status }), false];
      const run = latestActiveRun(t);
      if (!run) {
        if (a.runId === undefined) return [ok({ threadId: t.threadId, runId: null, status: "no_active_run" }), false];
        return [err("thread_not_interruptible", `Run ${a.runId} is not interruptible.`), false];
      }
      if (a.runId !== undefined && run.runId !== a.runId) return [err("thread_not_interruptible", `Run ${a.runId} is not interruptible.`), false];
      run.stopRequested = "interrupt";
      if (w.queueAfterInterrupt) run.queueAfterInterrupt = w.queueAfterInterrupt;
      return [ok({ threadId: t.threadId, runId: run.runId, status: "interrupt_requested" }), true];
    }
    case "t3_thread_organize": {
      if (!t) return [notFound(a.threadId), false];
      if (a.action === "archive") {
        t.archived = true;
        const run = latestActiveRun(t);
        if (run) run.stopRequested = "archive";
        else if (t.activeRunId && !w.archiveKeepsRun) {
          // A hand-written thread whose run list does not name its active run.
          t.activeRunId = null;
          t.status = "interrupted";
        }
      }
      return [ok({ threadId: t.threadId, action: a.action }), true];
    }
    case "t3_pending_request_list": {
      if (!t) return [notFound(a.threadId), false];
      return [ok({ requestIds: pendingRequests(t).filter((r) => r.kind === "user_input").map((r) => r.id) }), false];
    }
    case "t3_pending_request_read":
    case "t3_pending_request_respond": {
      if (!t) return [notFound(a.threadId), false];
      const q = pendingRequests(t).find((r) => r.id === a.requestId && r.kind === "user_input");
      if (!q) return [err("request_not_found", `Request ${a.requestId} is not a pending question in thread ${a.threadId}.`), false];
      if (name === "t3_pending_request_read") return [ok({ requestId: q.id, questions: q.questions ?? [] }), false];
      q.status = "resolved";
      q.answers = a.answers;
      return [ok({ sequence: 1 }), true];
    }
    default:
      return [err("unknown_tool", `no tool ${name}`), false];
  }
}

// t3_thread_wait: T3 selects the exact runId, else the latest run by ordinal,
// and resolves when that run is terminal or the timeout passes.
async function waitRun(a) {
  const deadline = Date.now() + Math.max(1, a.timeoutMs ?? 600_000);
  for (;;) {
    const w = loadWorld();
    if (settle(w)) saveWorld(w);
    const t = (w.threads ?? {})[a.threadId];
    if (!t) return notFound(a.threadId);
    const run = a.runId === undefined ? latestRun(t) : (t.runs ?? []).find((r) => r.runId === a.runId);
    if (a.runId !== undefined && !run) return err("run_not_found", `Run ${a.runId} is not in thread ${a.threadId}.`);
    if (!run) return ok({ threadId: t.threadId, runId: null, status: "idle", timedOut: false });
    if (!ACTIVE.has(run.status)) return ok({ threadId: t.threadId, runId: run.runId, status: run.status, timedOut: false });
    if (Date.now() >= deadline) return ok({ threadId: t.threadId, runId: run.runId, status: run.status, timedOut: true });
    await sleep(25);
  }
}

async function mcp(req, res) {
  const w = loadWorld();
  const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  const msg = JSON.parse(await body(req));
  const entry = { path: "/mcp", method: msg.method, tool: msg.params?.name, arguments: msg.params?.arguments, auth, protocol: req.headers["mcp-protocol-version"] };
  if (w.revoked || !(w.tokens ?? []).includes(auth)) {
    log(w, { ...entry, status: 401 });
    return json(res, 401, { error: "invalid_token" });
  }
  if (msg.method === "tools/call" && (w.dropTools ?? {})[msg.params.name] > 0) {
    w.dropTools[msg.params.name]--;
    saveWorld(w);
    log(w, { ...entry, dropped: true });
    return req.socket.destroy();
  }
  let result;
  if (msg.method === "initialize") {
    result = { protocolVersion: msg.params.protocolVersion, serverInfo: { name: "t3", version: w.serverVersion ?? "0.0.46-nightly.fake" }, capabilities: { tools: {} } };
  } else if (msg.method === "notifications/initialized") {
    log(w, entry);
    res.writeHead(202);
    return res.end();
  } else if (msg.method === "tools/list") {
    result = { tools: (w.tools ?? ALL_TOOLS).map((name) => ({ name, inputSchema: { type: "object" } })) };
  } else if (msg.method === "tools/call") {
    let changed = settle(w);
    let mutated;
    [result, mutated] = await callTool(w, msg.params.name, msg.params.arguments ?? {});
    changed = changed || mutated;
    // A wait re-reads the world while it blocks; never write back the stale copy.
    if (changed && msg.params.name !== "t3_thread_wait") saveWorld(w);
    if ((w.dropReplyTools ?? {})[msg.params.name] > 0) {
      const fresh = loadWorld();
      fresh.dropReplyTools[msg.params.name]--;
      saveWorld(fresh);
      log(fresh, { ...entry, replyDropped: true });
      return req.socket.destroy();
    }
  } else {
    return json(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
  }
  log(w, entry);
  const reply = { jsonrpc: "2.0", id: msg.id, result };
  const headers = { "mcp-session-id": "sess-fake" };
  if (w.sse) {
    res.writeHead(200, { "content-type": "text/event-stream", ...headers });
    return res.end(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
  }
  return json(res, 200, reply, headers);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  try {
    if (req.method === "POST" && url.pathname === "/mcp") return await mcp(req, res);
    if (req.method === "POST" && url.pathname === "/oauth/mcp/register") {
      const b = JSON.parse(await body(req));
      const id = `client-${randomBytes(4).toString("hex")}`;
      clients.set(id, b);
      log(loadWorld(), { path: url.pathname, client_name: b.client_name });
      return json(res, 201, { client_id: id });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/decision") {
      const b = JSON.parse(await body(req));
      log(loadWorld(), { path: url.pathname, tag: b.decision?._tag, access: b.decision?.access });
      if (b.decision?.code !== "PAIR-OK") return json(res, 400, { error: "invalid_pairing" });
      const code = randomBytes(8).toString("hex");
      codes.set(code, { challenge: b.authorization.code_challenge, access: b.decision.access });
      const to = new URL(b.authorization.redirect_uri);
      to.searchParams.set("code", code);
      to.searchParams.set("state", b.authorization.state);
      return json(res, 200, { redirectTo: to.href });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/token") {
      const b = new URLSearchParams(await body(req));
      const w = loadWorld();
      const entry = codes.get(b.get("code"));
      const challenge = createHash("sha256").update(b.get("code_verifier") ?? "").digest("base64url");
      log(w, { path: url.pathname, grant_type: b.get("grant_type"), pkce: Boolean(entry && entry.challenge === challenge) });
      if (!entry || entry.challenge !== challenge) return json(res, 400, { error: "invalid_grant" });
      const token = `tok-${randomBytes(12).toString("hex")}`;
      w.tokens = [...(w.tokens ?? []), token];
      saveWorld(w);
      return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: w.expiresIn ?? 2592000, scope: "orchestration:read orchestration:operate" });
    }
    json(res, 404, { error: "not_found" });
  } catch (e) {
    json(res, 500, { error: String(e) });
  }
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(args["port-file"], String(server.address().port));
});

if (args["parent-pid"]) {
  setInterval(() => {
    try {
      process.kill(Number(args["parent-pid"]), 0);
    } catch {
      process.exit(0);
    }
  }, 500).unref();
}
