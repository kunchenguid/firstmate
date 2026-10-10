#!/usr/bin/env node
// fm-t3-mcp.mjs - Firstmate's shell-callable client for a T3 Code server's
// Orchestrator V2 `/mcp` endpoint, the transport of the experimental `t3code`
// runtime backend (docs/t3code-backend.md owns the operator contract).
//
// Only bin/backends/t3code.sh and the captain's own sign-in call this; agents
// never do. Every verb opens one MCP streamable-HTTP session (protocol
// 2025-06-18, JSON or SSE replies), proves the server is the one the
// credential was issued by, runs the call, and prints exactly one JSON object
// on stdout.
//
// Usage:
//   fm-t3-mcp.mjs login --access full-access [--url <origin>] [--t3 <t3-bin>] [--base-dir <t3-base-dir>] [--label <label>]
//     Captain-run sign-in. Mints a two-minute one-time pairing code with the
//     operator's own `t3 auth pairing create --scope orchestration:read
//     --scope orchestration:operate`, spends it on T3's OAuth decision API at
//     the chosen ceiling, exchanges the code with a PKCE verifier, and writes
//     the credential, the server's origin, its environment id, and its version
//     to the token file (mode 0600). The token and pairing code are never
//     printed. Only the full-access ceiling is accepted. The origin defaults to
//     $FM_T3CODE_ORIGIN, else the `origin` in
//     ~/.t3/userdata/server-runtime.json.
//   fm-t3-mcp.mjs status
//     Credential expiry, the capability gate, and whether a loopback server's
//     own process runs with telemetry off (telemetry: off|on|unknown; anything
//     but off adds a stderr warning). Changes nothing.
//   fm-t3-mcp.mjs project-ensure --root <abs-path> [--title <title>]
//     The live T3 project whose workspaceRoot is <root> by real path, created
//     when absent.
//   fm-t3-mcp.mjs project-read --project <id>
//     That project's record (defaultModelSelection included); exit 3 with
//     code project_not_found when T3 lists no live project with that id.
//   fm-t3-mcp.mjs resolve-selection --harness <claude|codex> --instance <id>
//       --model <slug|default> --effort <level|default> [--project <id>]
//     The model selection a launch sends, resolved against T3's own catalog
//     (orchestrator_capabilities): the instance must exist, be usable, and run
//     the harness's driver (claude: claudeAgent, codex: codex); the model must
//     be one that instance lists; model default takes the project's default
//     selection, which must name the same instance. A non-default effort
//     replaces only the driver's reasoning option (claude: effort, codex:
//     reasoningEffort) and keeps every other default option; every option is
//     then checked against that model's descriptors. Exit 4 refuses.
//   fm-t3-mcp.mjs launch --project <id> --title <title> --model-selection <json>
//       [--worktree <abs-path>] [--branch <name>] [--message-file <file>]
//     t3_thread_launch at runtimeMode full-access. With --worktree the
//     workspace strategy is existing_worktree; without it, root (the project's
//     own checkout). Reads the thread and its t3_thread_configuration back and
//     archives and refuses it unless T3 bound exactly that workspace, full
//     access, instance, model, and every requested option value; a refused
//     thread whose archive fails exits 1, because it may still be live. A
//     read-back that fails also archives and exits 1, since the thread exists
//     but its binding is unproven. Without --message-file the thread is
//     created idle.
//   fm-t3-mcp.mjs send --thread <id> --message-file <file> --client-request-id <id>
//     t3_thread_send mode auto: start an idle thread's next turn or steer the
//     running one. T3 derives the message and command ids from the client
//     request id, so a retry with the same id is the same delivery. T3 commits
//     a send before it replies, so a reply lost after the request went out
//     exits 7 (delivery_unconfirmed): the message may have landed, and only a
//     retry with the same client request id is safe. A refusal before the
//     request went out, or T3's own typed refusal, is proven non-delivery for
//     this attempt; exit 3 is only T3's refusal of the send itself, so a
//     typed failure of the gate's reads exits 1.
//   fm-t3-mcp.mjs state --thread <id>
//     exists, archived, status, activeRunId, pendingRequestCount,
//     worktreePath, and turnAt (the latest run's completion, else its start or
//     request time); a thread the verified server does not have reads
//     exists:false.
//   fm-t3-mcp.mjs read --thread <id> [--limit <n>]
//     t3_thread_read: the thread record and its latest run, unchanged. T3
//     caps --limit at 100.
//   fm-t3-mcp.mjs capture --thread <id> [--lines <n>]
//     The activity view rendered as a bounded plain-text tail; the one verb
//     whose stdout is text rather than JSON.
//   fm-t3-mcp.mjs wait --thread <id> [--run <run-id>] [--timeout-ms <n>]
//     t3_thread_wait until that run (the latest run without --run) is
//     terminal or the timeout passes.
//   fm-t3-mcp.mjs interrupt --thread <id> [--timeout-ms <n>]
//     t3_thread_interrupt (T3 stops the latest active run), then
//     t3_thread_wait on exactly the run T3 named; cancel is confirmed only
//     when that run reads terminal, not-running when there was no active run,
//     and unconfirmed otherwise (timeout, or a wait that answered for a
//     different run). T3 ends the run asynchronously after the request.
//   fm-t3-mcp.mjs requests --thread <id>
//     The thread's pending runtime requests: questions (each user-input
//     request id with its questions, from t3_pending_request_list/read) and
//     approvals, the count of pending requests those tools cannot see or
//     answer (permission approvals, answered only in T3 Code itself).
//   fm-t3-mcp.mjs respond --thread <id> --request <request-id> --answers-file <file>
//     t3_pending_request_respond with the JSON object in <file>, keyed by
//     question id. It cannot approve a permission request.
//   fm-t3-mcp.mjs watch --thread <id>... --timeout-ms <n> [--escalated <id>=<signature>]...
//     The T3 event wait for the watcher. It first reads every thread: one
//     whose pending requests changed from its --escalated signature reports
//     event:blocked with that signature, its question ids, and its approval
//     count; a thread given --escalated with nothing pending is listed in
//     cleared. Otherwise it waits on the exact active run of every thread at
//     once and reports event:run-ended for the first that turns terminal,
//     event:timeout when none does, or event:none when no thread has an
//     active run (the caller sleeps instead of re-arming).
//   fm-t3-mcp.mjs archive --thread <id> [--timeout-ms <n>]
//     t3_thread_organize archive, then read back until the thread reports
//     archived:true and activeRunId:null (closed=true). A thread the verified
//     server no longer has is already closed (missing=true).
//   fm-t3-mcp.mjs thread-for-root --root <abs-path>
//     The one unarchived, worktree-less thread with an active run on the live
//     project rooted at <root>, across every t3_thread_list page; a fork
//     counts, a delegated subagent does not: exit 0 with threadId; exit 5
//     when there is none; exit 6 when there are several (threadIds names
//     them).
//
// Every verb accepts --token-file <path>. It defaults to
// $FM_T3CODE_TOKEN_FILE, else ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/t3code-token,
// with FM_HOME defaulting to this repository.
//
// The capability gate (every verb, login included) runs tools/list and refuses
// unless all of REQUIRED_TOOLS and t3_environment_read are present, then reads
// t3_environment_read and refuses unless its environmentId equals the one
// recorded at sign-in, so a different T3 on the same origin is never driven
// with this credential.
//
// Exit: 0 success; 1 transport or unexpected failure; 2 invalid use; 3 a typed
// T3 failure (tool error or JSON-RPC error; error.code carries T3's code when
// it has one); 4 a local refusal (no credential, expired credential, revoked
// credential, environment mismatch, capability gate, or a launch binding
// mismatch whose thread was archived); 5 and 6 as thread-for-root says; 7 a
// mutation whose request went out but whose reply was lost (send). A
// failure prints {"ok":false,"error":{...}} on stdout and one line on stderr.
// A credential within EXPIRY_WARN_DAYS of expiry adds a stderr warning on
// every verb and a `credentialWarning` field on status.

import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PROTOCOL = "2025-06-18";
export const REQUIRED_TOOLS = [
  "t3_thread_launch",
  "t3_thread_send",
  "t3_thread_read",
  "t3_thread_wait",
  "t3_thread_interrupt",
  "t3_thread_organize",
  "t3_thread_list",
  "t3_thread_configuration",
  "t3_project_list",
  "t3_project_create",
  "t3_pending_request_list",
  "t3_pending_request_read",
  "t3_pending_request_respond",
  "orchestrator_capabilities",
];
const ENVIRONMENT_TOOL = "t3_environment_read";
const EXPIRY_WARN_DAYS = 5;
const DAY_MS = 86_400_000;
const REQUEST_TIMEOUT_MS = 30_000;
const SCOPES = ["orchestration:read", "orchestration:operate"];
const ACCESS_CEILINGS = ["full-access"];
const TERMINAL_RUN = new Set(["completed", "failed", "cancelled", "interrupted", "rolled_back"]);
const ACTIVE_STATUSES = ["preparing", "queued", "starting", "running", "waiting"];
const READ_LIMIT_MAX = 100;
// Each Firstmate harness runs on one T3 driver, whose reasoning option id is
// part of that driver's protocol; the values come from T3's catalog.
const DRIVERS = {
  claude: { driverKind: "claudeAgent", effortOption: "effort" },
  codex: { driverKind: "codex", effortOption: "reasoningEffort" },
};
const REPEATABLE = new Set(["option", "thread", "escalated"]);

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

class Refusal extends Error {
  constructor(code, message, exit = 4, extra = {}) {
    super(message);
    this.code = code;
    this.exit = exit;
    this.extra = extra;
  }
}

function usage(message) {
  throw new Refusal("usage", message ?? "invalid use; see the header of bin/fm-t3-mcp.mjs", 2);
}

// Every flag takes one value; a repeatable flag also collects every value in
// flags.all[key], while flags[key] keeps the last.
function parseFlags(argv) {
  const flags = { all: {} };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) usage(`unexpected argument '${arg}'`);
    const key = arg.slice(2);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) usage(`--${key} needs a value`);
    i++;
    if (REPEATABLE.has(key)) (flags.all[key] ??= []).push(value);
    flags[key] = value;
  }
  return flags;
}

function need(flags, key) {
  const v = flags[key];
  if (v === undefined || v === "") usage(`--${key} is required`);
  return v;
}

function positiveInt(flags, key, fallback, max) {
  if (flags[key] === undefined) return fallback;
  const n = Number(flags[key]);
  if (!Number.isInteger(n) || n <= 0 || (max && n > max)) usage(`--${key} must be a positive integer${max ? ` up to ${max}` : ""}`);
  return n;
}

export function tokenFile(flags, env = process.env) {
  if (flags["token-file"]) return flags["token-file"];
  if (env.FM_T3CODE_TOKEN_FILE) return env.FM_T3CODE_TOKEN_FILE;
  const home = env.FM_HOME || env.FM_ROOT_OVERRIDE || root;
  const config = env.FM_CONFIG_OVERRIDE || path.join(home, "config");
  return path.join(config, "t3code-token");
}

// The sign-in origin: --url, else $FM_T3CODE_ORIGIN, else the origin the
// local T3 server writes to its runtime file.
export function loginOrigin(flags, env = process.env) {
  if (flags.url) return normalizeOrigin(flags.url);
  if (env.FM_T3CODE_ORIGIN) return normalizeOrigin(env.FM_T3CODE_ORIGIN);
  const runtime = path.join(env.HOME || os.homedir(), ".t3", "userdata", "server-runtime.json");
  let origin = "";
  try {
    origin = JSON.parse(readFileSync(runtime, "utf8")).origin || "";
  } catch {
    origin = "";
  }
  if (!origin) usage(`no T3 origin: pass --url, set FM_T3CODE_ORIGIN, or start T3 Code so it writes ${runtime}`);
  return normalizeOrigin(origin);
}

function normalizeOrigin(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    usage(`--url '${raw}' is not a URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") usage("--url must be http or https");
  return url.origin;
}

// --- credential ---------------------------------------------------------

export function readCredential(file, now = Date.now()) {
  if (!existsSync(file)) {
    throw new Refusal("no_credential", `no T3 credential at ${file}; the captain signs in with: bin/fm-t3-mcp.mjs login --access full-access`);
  }
  const mode = statSync(file).mode & 0o777;
  if (mode & 0o077) {
    throw new Refusal("credential_permissions", `T3 credential ${file} is readable by others (mode ${mode.toString(8)}); chmod 600 it or sign in again`);
  }
  let cred;
  try {
    cred = JSON.parse(readFileSync(file, "utf8"));
  } catch (err) {
    throw new Refusal("credential_unreadable", `T3 credential ${file} is not valid JSON: ${err.message}`);
  }
  for (const key of ["origin", "access_token", "expires_at", "environment_id"]) {
    if (!cred[key]) throw new Refusal("credential_unreadable", `T3 credential ${file} lacks ${key}; sign in again`);
  }
  if (cred.expires_at <= now) {
    throw new Refusal("credential_expired", `T3 credential ${file} expired at ${new Date(cred.expires_at).toISOString()}; T3 issues no refresh token, so the captain signs in again`);
  }
  const daysLeft = (cred.expires_at - now) / DAY_MS;
  if (daysLeft <= EXPIRY_WARN_DAYS) {
    cred.warning = `T3 credential expires in ${daysLeft.toFixed(1)} days (${new Date(cred.expires_at).toISOString()}); the captain signs in again before then`;
    process.stderr.write(`warning: ${cred.warning}\n`);
  }
  return cred;
}

function writeCredential(file, record) {
  mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(record)}\n`, { mode: 0o600, flag: "wx" });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
}

// --- MCP streamable HTTP ------------------------------------------------

async function httpJson(url, init) {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(init.timeoutMs ?? REQUEST_TIMEOUT_MS) });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return { res, body, text };
}

async function postJson(url, payload) {
  const { res, body } = await httpJson(url, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok || body === null) {
    const detail = body?.error_description || body?.error || body?.message || `HTTP ${res.status}`;
    throw new Refusal("oauth_failed", `${new URL(url).pathname} failed: ${detail}`, 3);
  }
  return body;
}

export class McpSession {
  constructor(origin, token, timeoutMs = REQUEST_TIMEOUT_MS) {
    this.origin = origin;
    this.token = token;
    this.sid = null;
    this.nextId = 1;
    this.timeoutMs = timeoutMs;
    this.server = null;
  }

  async rpc(method, params, { notify = false, timeoutMs, signal } = {}) {
    const body = notify ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", id: this.nextId++, method, params };
    const headers = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      authorization: `Bearer ${this.token}`,
      "mcp-protocol-version": PROTOCOL,
    };
    if (this.sid) headers["mcp-session-id"] = this.sid;
    let res;
    try {
      res = await fetch(`${this.origin}/mcp`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs ?? this.timeoutMs)]) : AbortSignal.timeout(timeoutMs ?? this.timeoutMs),
      });
    } catch (err) {
      throw new Refusal("transport", `T3 at ${this.origin} is unreachable: ${err.cause?.code || err.name}: ${err.message}`, 1);
    }
    this.sid = res.headers.get("mcp-session-id") ?? this.sid;
    const text = await res.text();
    if (res.status === 401 || res.status === 403) {
      throw new Refusal("unauthorized", `T3 at ${this.origin} rejected the credential (HTTP ${res.status}); it was revoked or belongs to another server, so the captain signs in again`, 4);
    }
    if (!res.ok && res.status !== 202) {
      throw new Refusal("transport", `T3 /mcp answered HTTP ${res.status}`, 1);
    }
    if (notify || res.status === 202 || text.length === 0) return null;
    let msg = null;
    if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) {
      for (const line of text.split("\n")) {
        if (!line.startsWith("data:")) continue;
        let m;
        try {
          m = JSON.parse(line.slice(5));
        } catch {
          continue;
        }
        if (m.id === body.id) msg = m;
      }
    } else {
      try {
        msg = JSON.parse(text);
      } catch {
        throw new Refusal("transport", "T3 /mcp returned a body that is not JSON", 1);
      }
    }
    if (!msg) throw new Refusal("transport", `T3 /mcp returned no reply to ${method}`, 1);
    if (msg.error) {
      throw new Refusal(String(msg.error.code ?? "rpc_error"), `T3 ${method} failed: ${msg.error.message ?? "unknown error"}`, 3);
    }
    return msg.result;
  }

  async open() {
    this.server = await this.rpc("initialize", {
      protocolVersion: PROTOCOL,
      capabilities: {},
      clientInfo: { name: "firstmate", version: "1" },
    });
    await this.rpc("notifications/initialized", undefined, { notify: true });
    return this.server;
  }

  // tools/call; a result flagged isError is a typed T3 failure (exit 3).
  async call(name, args, opts) {
    const result = await this.rpc("tools/call", { name, arguments: args ?? {} }, opts);
    const data = result?.structuredContent ?? parseContentJson(result?.content);
    if (result?.isError) {
      const err = toolError(data, result?.content);
      throw new Refusal(err.code, `T3 ${name} failed: ${err.message}`, 3, { tool: name });
    }
    return data;
  }
}

function parseContentJson(content) {
  if (!Array.isArray(content)) return null;
  for (const item of content) {
    if (item?.type !== "text") continue;
    try {
      return JSON.parse(item.text);
    } catch {
      return { text: item.text };
    }
  }
  return null;
}

function toolError(data, content) {
  const e = data?.error ?? data ?? {};
  const text = Array.isArray(content) ? content.filter((c) => c?.type === "text").map((c) => c.text).join(" ") : "";
  return {
    code: String(e.code ?? e._tag ?? e.type ?? "tool_error"),
    message: String(e.message ?? e.detail ?? (text || "unknown error")),
  };
}

// The capability gate: required tools present, environment id unchanged.
export async function gate(session, cred) {
  const server = await session.open();
  const listed = await session.rpc("tools/list", {});
  const names = new Set((listed?.tools ?? []).map((t) => t.name));
  const version = server?.serverInfo?.version ?? null;
  const missing = REQUIRED_TOOLS.filter((t) => !names.has(t));
  if (missing.length) {
    throw new Refusal(
      "capability_gate",
      `T3 ${version ?? "(unknown version)"} at ${session.origin} lacks ${missing.join(", ")}; backend=t3code needs a T3 with the Orchestrator V2 thread tools (docs/t3code-backend.md)`,
      4,
      { serverVersion: version, missing },
    );
  }
  if (!names.has(ENVIRONMENT_TOOL)) {
    throw new Refusal("capability_gate", `T3 ${version} lacks ${ENVIRONMENT_TOOL}, so its identity cannot be verified`, 4, { serverVersion: version });
  }
  const envRead = await session.call(ENVIRONMENT_TOOL, {});
  const environmentId = envRead?.environmentId ?? envRead?.environment?.environmentId ?? null;
  if (!environmentId) throw new Refusal("capability_gate", `${ENVIRONMENT_TOOL} returned no environmentId`, 4);
  if (cred && cred.environment_id !== environmentId) {
    throw new Refusal(
      "environment_mismatch",
      `T3 at ${session.origin} is environment ${environmentId}, not the ${cred.environment_id} this credential was issued by; refusing to drive a different server`,
      4,
      { environmentId, expected: cred.environment_id },
    );
  }
  return { serverVersion: version, environmentId, serverVersionReported: envRead?.serverVersion ?? null, tools: [...names].sort() };
}

async function verifiedSession(flags) {
  const cred = readCredential(tokenFile(flags));
  const session = new McpSession(cred.origin, cred.access_token);
  const g = await gate(session, cred);
  return { cred, session, gate: g };
}

function isNotFound(err) {
  return err instanceof Refusal && err.exit === 3 && /not[_ ]found/i.test(err.code);
}

// T3 product telemetry is on unless the server process runs with
// T3CODE_TELEMETRY_ENABLED false (apps/server's AnalyticsService config).
// Only a loopback server's own process environment can show that, read from
// the listening process on this machine; anything else reads `unknown`.
export function telemetryState(origin, probe = probeListenerEnv) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    return "unknown";
  }
  if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) return "unknown";
  const env = probe(url.port || (url.protocol === "https:" ? "443" : "80"));
  if (env === null) return "unknown";
  const m = env.match(/(?:^|\s|\0)T3CODE_TELEMETRY_ENABLED=([^\s\0]*)/);
  if (!m) return "on";
  return /^(false|0|no|off)$/i.test(m[1]) ? "off" : "on";
}

function probeListenerEnv(port) {
  try {
    const pids = execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .split("\n")
      .filter(Boolean);
    if (pids.length !== 1) return null;
    if (process.platform === "linux") return readFileSync(`/proc/${pids[0]}/environ`, "utf8");
    return execFileSync("ps", ["eww", "-o", "command=", "-p", pids[0]], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return null;
  }
}

// --- verbs ----------------------------------------------------------------

async function login(flags) {
  const access = need(flags, "access");
  if (!ACCESS_CEILINGS.includes(access)) {
    usage(`--access ${access} is not supported: Firstmate workers write their status outside the worktree, which only the full-access ceiling allows (docs/t3code-backend.md)`);
  }
  const origin = loginOrigin(flags);
  const file = tokenFile(flags);
  const t3 = flags.t3 || "t3";
  const label = flags.label || "firstmate";
  const redirect = "http://127.0.0.1:1/fm-t3-callback"; // never contacted: the decision API returns the redirect
  const reg = await postJson(`${origin}/oauth/mcp/register`, { client_name: label, redirect_uris: [redirect] });
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = randomBytes(12).toString("base64url");
  const resource = `${origin}/mcp`;
  const authorization = {
    response_type: "code",
    client_id: reg.client_id,
    redirect_uri: redirect,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    resource,
  };
  const pairingArgs = ["auth", "pairing", "create"];
  if (flags["base-dir"]) pairingArgs.push("--base-dir", flags["base-dir"]);
  for (const scope of SCOPES) pairingArgs.push("--scope", scope);
  pairingArgs.push("--ttl", "2m", "--label", `${label}-mcp-approval`, "--json");
  let pairing;
  try {
    pairing = JSON.parse(execFileSync(t3, pairingArgs, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
  } catch (err) {
    throw new Refusal("pairing_failed", `could not mint a pairing code with '${t3} auth pairing create': ${err.status !== undefined ? `exit ${err.status}` : err.message}`, 1);
  }
  if (!pairing?.credential) throw new Refusal("pairing_failed", "t3 auth pairing create returned no credential", 1);
  const decision = await postJson(`${origin}/oauth/mcp/decision`, {
    authorization,
    decision: { _tag: "pairing-code", access, code: pairing.credential },
  });
  const back = new URL(decision.redirectTo);
  if (back.searchParams.get("state") !== state) throw new Refusal("oauth_failed", "OAuth state mismatch on the decision redirect", 3);
  const code = back.searchParams.get("code");
  if (!code) throw new Refusal("oauth_failed", `the decision returned no code (${back.searchParams.get("error") ?? "no error given"})`, 3);
  const { res, body: tok } = await httpJson(`${origin}/oauth/mcp/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: redirect, client_id: reg.client_id, code_verifier: verifier, resource }),
  });
  if (!res.ok || !tok?.access_token) throw new Refusal("oauth_failed", `token exchange failed: ${tok?.error_description ?? tok?.error ?? `HTTP ${res.status}`}`, 3);
  const issuedAt = Date.now();
  const session = new McpSession(origin, tok.access_token);
  const g = await gate(session, null);
  const record = {
    version: 1,
    origin,
    access_token: tok.access_token,
    issued_at: issuedAt,
    expires_at: issuedAt + Number(tok.expires_in) * 1000,
    scope: tok.scope,
    access,
    label,
    client_id: reg.client_id,
    environment_id: g.environmentId,
    server_version: g.serverVersion,
  };
  writeCredential(file, record);
  return {
    ok: true,
    tokenFile: file,
    origin,
    access,
    scope: tok.scope,
    expiresAt: new Date(record.expires_at).toISOString(),
    environmentId: g.environmentId,
    serverVersion: g.serverVersion,
  };
}

async function status(flags) {
  const { cred, gate: g } = await verifiedSession(flags);
  const telemetry = telemetryState(cred.origin);
  if (telemetry !== "off") {
    process.stderr.write(`warning: T3 telemetry at ${cred.origin} is ${telemetry === "on" ? "on" : "not confirmed off"}; run the server that hosts Firstmate workers with T3CODE_TELEMETRY_ENABLED=false (docs/t3code-backend.md)\n`);
  }
  return {
    ok: true,
    origin: cred.origin,
    access: cred.access,
    expiresAt: new Date(cred.expires_at).toISOString(),
    daysLeft: Number(((cred.expires_at - Date.now()) / DAY_MS).toFixed(1)),
    environmentId: g.environmentId,
    serverVersion: g.serverVersion,
    recordedServerVersion: cred.server_version ?? null,
    telemetry,
    ...(cred.warning ? { credentialWarning: cred.warning } : {}),
  };
}

// state: whether the thread exists, and its archive and run state. A thread
// the verified server does not have reads exists:false rather than failing.
async function state(flags) {
  const threadId = need(flags, "thread");
  const { session } = await verifiedSession(flags);
  let out;
  try {
    out = await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 });
  } catch (err) {
    if (isNotFound(err)) return { ok: true, threadId, exists: false };
    throw err;
  }
  const t = threadOf(out);
  const run = (out?.recentRuns ?? [])[0] ?? {};
  return {
    ok: true,
    threadId,
    exists: true,
    archived: t.archived === true || Boolean(t.archivedAt),
    status: t.status ?? null,
    activeRunId: t.activeRunId ?? null,
    pendingRequestCount: t.pendingRequestCount ?? 0,
    worktreePath: t.worktreePath ?? null,
    turnAt: run.completedAt ?? run.startedAt ?? run.requestedAt ?? null,
  };
}

function realOrRaw(p) {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

// Every live project, across t3_project_list pages.
async function liveProjects(session) {
  const projects = [];
  let cursor;
  for (let page = 0; page < 100; page++) {
    const listed = await session.call("t3_project_list", { limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
    projects.push(...(listed?.projects ?? []));
    if (listed?.nextCursor === null || listed?.nextCursor === undefined) break;
    cursor = listed.nextCursor;
  }
  return projects.filter((p) => !p.deletedAt);
}

async function projectForRoot(session, rootPath) {
  const want = realOrRaw(rootPath);
  return (await liveProjects(session)).find((p) => realOrRaw(p.workspaceRoot ?? "") === want) ?? null;
}

async function projectEnsure(flags) {
  const rootPath = need(flags, "root");
  if (!path.isAbsolute(rootPath)) usage("--root must be an absolute path");
  const { session } = await verifiedSession(flags);
  const found = await projectForRoot(session, rootPath);
  if (found) return { ok: true, projectId: found.id, created: false };
  const made = await session.call("t3_project_create", { title: flags.title || path.basename(rootPath), workspaceRoot: realOrRaw(rootPath) });
  const projectId = made?.id ?? made?.projectId ?? made?.project?.id;
  if (!projectId) throw new Refusal("project_unconfirmed", "t3_project_create returned no project id", 1);
  return { ok: true, projectId, created: true };
}

async function projectRead(flags) {
  const projectId = need(flags, "project");
  const { session } = await verifiedSession(flags);
  const project = (await liveProjects(session)).find((p) => p.id === projectId);
  if (!project) throw new Refusal("project_not_found", `T3 lists no live project ${projectId}`, 3);
  return { ok: true, project };
}

function readMessage(flags) {
  const file = need(flags, "message-file");
  const text = readFileSync(file, "utf8");
  if (!text.trim()) usage(`--message-file ${file} is empty`);
  return text;
}

function modelSelection(flags) {
  let sel;
  try {
    sel = JSON.parse(need(flags, "model-selection"));
  } catch {
    usage("--model-selection must be JSON");
  }
  if (!sel || typeof sel.instanceId !== "string" || !sel.instanceId || typeof sel.model !== "string" || !sel.model) {
    usage("--model-selection needs a string instanceId and model");
  }
  return sel;
}

// An option selection is valid when the model's catalog describes its id and,
// for a select, lists its value; a boolean option takes a boolean.
function optionProblem(model, option) {
  const descriptor = (model.options ?? []).find((d) => d.id === option.id);
  if (!descriptor) return `option '${option.id}' is not one model ${model.id} offers`;
  if (descriptor.type === "boolean") return typeof option.value === "boolean" ? null : `option '${option.id}' takes true or false`;
  const values = (descriptor.options ?? []).map((c) => c.id);
  return values.includes(option.value) ? null : `option '${option.id}' value '${option.value}' is not one of ${values.join(", ")} for model ${model.id}`;
}

async function resolveSelection(flags) {
  const harness = need(flags, "harness");
  const driver = DRIVERS[harness];
  if (!driver) throw new Refusal("harness_unsupported", `backend=t3code supports only the claude and codex harnesses, not '${harness}'`);
  const instanceId = need(flags, "instance");
  const wantModel = need(flags, "model");
  const effort = need(flags, "effort");
  const { session } = await verifiedSession(flags);
  const caps = await session.call("orchestrator_capabilities", {});
  const provider = (caps?.providers ?? []).find((p) => p.providerInstanceId === instanceId);
  if (!provider) throw new Refusal("instance_unknown", `T3 has no provider instance '${instanceId}' (config/t3code-instances maps the ${harness} harness to it)`);
  if (provider.driverKind !== driver.driverKind) {
    throw new Refusal("driver_mismatch", `T3 instance '${instanceId}' runs the ${provider.driverKind} driver, not ${driver.driverKind}, so it cannot host the ${harness} harness; fix config/t3code-instances`);
  }
  if ((provider.constraints ?? []).length) throw new Refusal("instance_unavailable", `T3 instance '${instanceId}' cannot run threads: ${provider.constraints.join(" ")}`);
  let base = { instanceId, model: wantModel };
  if (wantModel === "default") {
    const projectId = need(flags, "project");
    const project = (await liveProjects(session)).find((p) => p.id === projectId);
    if (!project) throw new Refusal("project_not_found", `T3 lists no live project ${projectId}`, 3);
    const def = project.defaultModelSelection;
    if (!def) throw new Refusal("no_default_model", `T3 project ${projectId} has no default model; pass --model with a slug from the T3 model catalog`);
    if (def.instanceId !== instanceId) {
      throw new Refusal("default_instance_mismatch", `T3 project ${projectId} defaults to instance ${def.instanceId}, but config/t3code-instances selects ${instanceId}; pass --model explicitly`);
    }
    base = { instanceId, model: def.model, ...(def.options !== undefined ? { options: def.options } : {}) };
  }
  const model = (provider.models ?? []).find((m) => m.id === base.model);
  if (!model) throw new Refusal("model_unknown", `T3 instance '${instanceId}' does not list model '${base.model}'; pass --model with a slug from its catalog`);
  let options = base.options;
  if (effort !== "default") {
    const chosen = { id: driver.effortOption, value: effort };
    const problem = optionProblem(model, chosen);
    if (problem) throw new Refusal("effort_unsupported", `backend=t3code cannot pass effort '${effort}' to harness '${harness}': ${problem}`);
    const kept = options ?? [];
    options = kept.some((o) => o.id === chosen.id) ? kept.map((o) => (o.id === chosen.id ? chosen : o)) : [...kept, chosen];
  }
  for (const option of options ?? []) {
    const problem = optionProblem(model, option);
    if (problem) throw new Refusal("option_unsupported", `the selection for harness '${harness}' is not valid in T3's catalog: ${problem}`);
  }
  return { ok: true, driverKind: provider.driverKind, selection: { instanceId, model: base.model, ...(options !== undefined ? { options } : {}) } };
}

// What a launch must read back: the workspace, full access, and exactly the
// requested instance, model, and option values.
function bindingProblems(t, config, selection, worktree) {
  const problems = [];
  if (worktree ? realOrRaw(t.worktreePath ?? "") !== realOrRaw(worktree) : (t.worktreePath ?? null) !== null) {
    problems.push(`worktreePath ${t.worktreePath ?? "none"}`);
  }
  if (t.runtimeMode !== "full-access" || config?.runtimeMode !== "full-access") problems.push(`runtimeMode ${config?.runtimeMode ?? t.runtimeMode ?? "none"}`);
  const bound = config?.modelSelection ?? {};
  if (t.providerInstanceId !== selection.instanceId || bound.instanceId !== selection.instanceId) problems.push(`provider ${bound.instanceId ?? t.providerInstanceId ?? "none"}`);
  if (bound.model !== selection.model) problems.push(`model ${bound.model ?? "none"}`);
  for (const option of selection.options ?? []) {
    const got = (bound.options ?? []).find((o) => o.id === option.id);
    if (got?.value !== option.value) problems.push(`option ${option.id}=${got ? got.value : "none"}`);
  }
  return problems;
}

async function launch(flags) {
  const worktree = flags.worktree;
  if (worktree !== undefined && !path.isAbsolute(worktree)) usage("--worktree must be an absolute path");
  const selection = modelSelection(flags);
  const message = flags["message-file"] ? readMessage(flags) : null;
  const { session, gate: g } = await verifiedSession(flags);
  const workspaceStrategy = worktree
    ? { type: "existing_worktree", worktreePath: worktree, ...(flags.branch ? { branch: flags.branch } : {}) }
    : { type: "root", ...(flags.branch ? { branch: flags.branch } : {}) };
  const args = {
    projectId: need(flags, "project"),
    title: need(flags, "title"),
    modelSelection: selection,
    runtimeMode: "full-access",
    interactionMode: "default",
    workspaceStrategy,
    ...(message ? { message } : {}),
  };
  const out = await session.call("t3_thread_launch", args);
  if (!out?.threadId) throw new Refusal("launch_unconfirmed", "t3_thread_launch returned no threadId; inspect t3_thread_list before retrying", 1);
  const archiveLaunched = () => session.call("t3_thread_organize", { threadId: out.threadId, action: "archive" }).then(() => true, () => false);
  // Prove the binding T3 recorded before anyone relies on it.
  let t;
  let config;
  try {
    t = threadOf(await session.call("t3_thread_read", { threadId: out.threadId, limit: 1, runLimit: 1 }));
    config = await session.call("t3_thread_configuration", { threadId: out.threadId });
  } catch (e) {
    const archived = await archiveLaunched();
    throw new Refusal(
      "binding_unconfirmed",
      `T3 launched thread ${out.threadId} but reading back its binding failed (${e.message}); ${archived ? "asked T3 to archive it, so confirm it is archived" : "its archive failed, so archive it"} in T3 Code`,
      1,
      { threadId: out.threadId },
    );
  }
  const problems = bindingProblems(t, config, selection, worktree);
  if (problems.length) {
    const archived = await archiveLaunched();
    throw new Refusal(
      "binding_mismatch",
      `T3 bound thread ${out.threadId} to ${problems.join(", ")}, not the requested ${worktree ? "worktree" : "project root"} and model selection at full access; ${archived ? "archived it" : "its archive failed, so archive it in T3 Code"}`,
      archived ? 4 : 1,
      { threadId: out.threadId },
    );
  }
  return {
    ok: true,
    threadId: out.threadId,
    projectId: out.projectId ?? args.projectId,
    instanceId: selection.instanceId,
    model: selection.model,
    runId: out.runId ?? null,
    status: t.status ?? null,
    environmentId: g.environmentId,
    origin: session.origin,
    serverVersion: g.serverVersion,
  };
}

async function send(flags) {
  const args = { threadId: need(flags, "thread"), message: readMessage(flags), mode: "auto", clientRequestId: need(flags, "client-request-id") };
  let session;
  try {
    ({ session } = await verifiedSession(flags));
  } catch (err) {
    // Exit 3 means T3 refused this send; a typed failure of the gate's own
    // reads is a failure before the request went out.
    if (err instanceof Refusal && err.exit === 3) throw new Refusal(err.code, err.message, 1, err.extra);
    throw err;
  }
  let out;
  try {
    out = await session.call("t3_thread_send", args);
  } catch (err) {
    // A typed T3 refusal (3) or a refused credential (4) proves the message
    // was not taken; anything else happened after the request went out.
    if (err instanceof Refusal && (err.exit === 3 || err.exit === 4)) throw err;
    throw new Refusal(
      "delivery_unconfirmed",
      `the reply to t3_thread_send on thread ${args.threadId} was lost (${err.message}); T3 may have committed it, so retry only with client request id ${args.clientRequestId}`,
      7,
      { threadId: args.threadId, clientRequestId: args.clientRequestId },
    );
  }
  return { ok: true, threadId: args.threadId, clientRequestId: args.clientRequestId, delivery: out?.delivery ?? null, status: out?.status ?? null, runId: out?.runId ?? null, messageId: out?.messageId ?? null };
}

async function read(flags) {
  const { session } = await verifiedSession(flags);
  const out = await session.call("t3_thread_read", { threadId: need(flags, "thread"), limit: positiveInt(flags, "limit", 1, READ_LIMIT_MAX), runLimit: 1 });
  return { ok: true, ...out };
}

function itemText(item) {
  const raw = item?.text ?? item?.summary ?? item?.title ?? item?.message ?? item?.detail ?? "";
  return String(typeof raw === "string" ? raw : JSON.stringify(raw)).replace(/\s+/g, " ").trim();
}

// One `[type/status] text` line per activity item, then the thread's own
// status line last, so the tightest bound still shows the run state.
export function renderCapture(out, lines) {
  const t = out?.thread ?? {};
  const items = out?.items ?? [];
  const body = items.map((it) => {
    const kind = it?.type ?? "item";
    const st = it?.status ? `/${it.status}` : "";
    return `[${kind}${st}] ${itemText(it)}`.slice(0, 600);
  });
  const archived = t.archived === true || Boolean(t.archivedAt);
  const tail = `t3code: status=${archived ? "archived" : (t.status ?? "none")} run=${t.activeRunId ?? "none"}`;
  return [...body, tail].slice(-lines).join("\n");
}

// t3_thread_read pages forward from the oldest item, so the tail starts from
// the thread's itemCount and widens backwards if that undercounts the visible
// timeline (forked or handed-off threads).
async function capture(flags) {
  const threadId = need(flags, "thread");
  const lines = positiveInt(flags, "lines", 40, 500);
  const { session } = await verifiedSession(flags);
  const read = (afterPosition) =>
    session.call("t3_thread_read", { threadId, view: "activity", limit: READ_LIMIT_MAX, maxCharsPerItem: 600, runLimit: 1, ...(afterPosition >= 0 ? { afterPosition } : {}) });
  const head = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
  let start = Math.max(0, (head.itemCount ?? 0) - lines);
  for (;;) {
    let out = await read(start - 1);
    const items = [...(out?.items ?? [])];
    for (let page = 0; out?.hasMore && out.nextPosition !== null && page < 50; page++) {
      out = await read(out.nextPosition);
      items.push(...(out?.items ?? []));
    }
    if (items.length >= lines || start === 0) return { text: renderCapture({ ...out, items: items.slice(-lines) }, lines) };
    start = Math.max(0, start - lines);
  }
}

// One t3_thread_wait; runId selects the exact run, else T3 waits on the
// thread's latest run.
function waitRun(session, threadId, runId, timeoutMs, signal) {
  return session.call("t3_thread_wait", { threadId, ...(runId ? { runId } : {}), timeoutMs }, { timeoutMs: timeoutMs + 15_000, signal });
}

async function wait(flags) {
  const timeoutMs = positiveInt(flags, "timeout-ms", 600_000, 3_600_000);
  const { session } = await verifiedSession(flags);
  const out = await waitRun(session, need(flags, "thread"), flags.run, timeoutMs);
  return { ok: true, ...out };
}

// cancel: confirmed (the run T3 interrupted reached a terminal status),
// not-running (there was no active run), or unconfirmed (the wait timed out
// or answered for another run). T3 interrupts its latest active run and ends
// it asynchronously, while a run queued behind it may already be terminal or
// start meanwhile, so only that exact run's state counts.
async function interrupt(flags) {
  const threadId = need(flags, "thread");
  const timeoutMs = positiveInt(flags, "timeout-ms", 10_000, 600_000);
  const { session } = await verifiedSession(flags);
  const requested = await session.call("t3_thread_interrupt", { threadId, clientRequestId: `fm-interrupt-${Date.now()}-${randomBytes(4).toString("hex")}` });
  if (requested?.status === "no_active_run") return { ok: true, threadId, requested: requested.status, cancel: "not-running" };
  const runId = requested?.runId ?? null;
  const base = { ok: true, threadId, runId, requested: requested?.status ?? null };
  if (!runId) return { ...base, cancel: "unconfirmed" };
  if (TERMINAL_RUN.has(requested.status)) return { ...base, status: requested.status, timedOut: false, cancel: "confirmed" };
  const waited = await waitRun(session, threadId, runId, timeoutMs);
  const done = waited?.runId === runId && waited?.timedOut !== true && TERMINAL_RUN.has(waited?.status);
  return { ...base, waitedRunId: waited?.runId ?? null, status: waited?.status ?? null, timedOut: waited?.timedOut === true, cancel: done ? "confirmed" : "unconfirmed" };
}

function threadOf(out) {
  return out?.thread ?? out ?? {};
}

// The pending runtime requests on one thread: the questions T3's
// pending-request tools can read and answer, and the remainder of
// pendingRequestCount, which are approvals those tools cannot see.
async function pendingOf(session, threadId, pendingRequestCount) {
  if (!pendingRequestCount) return { questions: [], approvals: 0 };
  const listed = await session.call("t3_pending_request_list", { threadId });
  const ids = [...new Set(listed?.requestIds ?? [])].sort();
  return { questions: ids, approvals: Math.max(0, pendingRequestCount - ids.length) };
}

// The signature the watcher stores once it has escalated a thread's pending
// requests, so the same requests never wake it twice.
const pendingSignature = (p) => `q:${p.questions.join(",")};a:${p.approvals}`;

async function requests(flags) {
  const threadId = need(flags, "thread");
  const { session } = await verifiedSession(flags);
  const t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
  const pending = await pendingOf(session, threadId, t.pendingRequestCount ?? 0);
  const questions = [];
  for (const requestId of pending.questions) {
    const q = await session.call("t3_pending_request_read", { threadId, requestId });
    questions.push({ requestId, questions: q?.questions ?? [] });
  }
  return { ok: true, threadId, pendingRequestCount: t.pendingRequestCount ?? 0, questions, approvals: pending.approvals, signature: pendingSignature(pending) };
}

async function respond(flags) {
  const threadId = need(flags, "thread");
  const requestId = need(flags, "request");
  const file = need(flags, "answers-file");
  let answers;
  try {
    answers = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    usage(`--answers-file ${file} must hold JSON`);
  }
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) usage("--answers-file must hold a JSON object keyed by question id");
  const { session } = await verifiedSession(flags);
  await session.call("t3_pending_request_respond", { threadId, requestId, answers });
  return { ok: true, threadId, requestId };
}

// watch: one bounded supervision wait across threads (see the header).
async function watch(flags) {
  const threadIds = [...new Set(flags.all.thread ?? [])];
  if (!threadIds.length) usage("--thread is required");
  const timeoutMs = positiveInt(flags, "timeout-ms", 60_000, 3_600_000);
  const escalated = new Map();
  for (const pair of flags.all.escalated ?? []) {
    const eq = pair.indexOf("=");
    if (eq <= 0) usage("--escalated takes <thread-id>=<signature>");
    escalated.set(pair.slice(0, eq), pair.slice(eq + 1));
  }
  const { session } = await verifiedSession(flags);
  const cleared = [];
  const runs = [];
  for (const threadId of threadIds) {
    let t;
    try {
      t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
    } catch (err) {
      if (isNotFound(err)) continue;
      throw err;
    }
    if (t.archived === true || t.archivedAt) continue;
    const pending = await pendingOf(session, threadId, t.pendingRequestCount ?? 0);
    const signature = pendingSignature(pending);
    if (pending.questions.length || pending.approvals) {
      if (escalated.get(threadId) !== signature) return { ok: true, event: "blocked", threadId, signature, questions: pending.questions, approvals: pending.approvals, cleared };
    } else if (escalated.has(threadId)) {
      cleared.push(threadId);
    }
    if (t.activeRunId) runs.push({ threadId, runId: t.activeRunId });
  }
  if (!runs.length) return { ok: true, event: "none", cleared };
  const abort = new AbortController();
  try {
    const ended = await Promise.any(
      runs.map(async ({ threadId, runId }) => {
        const waited = await waitRun(session, threadId, runId, timeoutMs, abort.signal);
        if (waited?.runId === runId && waited?.timedOut !== true && TERMINAL_RUN.has(waited?.status)) return { threadId, runId, status: waited.status };
        throw new Error("not ended");
      }),
    ).catch(() => null);
    return ended ? { ok: true, event: "run-ended", ...ended, cleared } : { ok: true, event: "timeout", cleared };
  } finally {
    abort.abort();
  }
}

async function archive(flags) {
  const threadId = need(flags, "thread");
  const timeoutMs = positiveInt(flags, "timeout-ms", 15_000, 600_000);
  const { session } = await verifiedSession(flags);
  try {
    await session.call("t3_thread_organize", { threadId, action: "archive" });
  } catch (err) {
    if (isNotFound(err)) return { ok: true, threadId, closed: true, missing: true };
    // An already-archived thread is the end state; the read-back decides.
    if (!(err instanceof Refusal && /archiv/i.test(err.message))) throw err;
  }
  const deadline = Date.now() + timeoutMs;
  let t = {};
  for (;;) {
    t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
    const archived = t.archived === true || Boolean(t.archivedAt);
    if (archived && (t.activeRunId ?? null) === null) {
      return { ok: true, threadId, closed: true, archived: true, activeRunId: null, status: t.status ?? null };
    }
    if (Date.now() >= deadline) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Refusal("close_unproven", `thread ${threadId} did not read back archived with no active run within ${timeoutMs} ms (archived=${t.archived === true || Boolean(t.archivedAt)}, activeRunId=${t.activeRunId ?? null})`, 3, { thread: t });
}

// Every thread T3 lists for a project with the given statuses, across pages,
// without delegated subagents.
async function listThreads(session, projectId, statuses) {
  const seen = new Map();
  let cursor;
  for (let page = 0; page < 1000; page++) {
    const listed = await session.call("t3_thread_list", { projectId, statuses, includeSubagents: false, limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
    for (const item of listed?.threads ?? []) seen.set(item.threadId, item);
    if (listed?.nextCursor === null || listed?.nextCursor === undefined) break;
    cursor = listed.nextCursor;
  }
  return [...seen.values()];
}

// thread-for-root: away-mode supervisor discovery. T3 puts no thread id into
// the agent's environment, so the only self-discovery is a cwd match: on the
// project rooted at <root>, the unarchived thread with no worktree of its own
// whose run is active (the daemon starts from inside the captain's own turn).
// A fork is an ordinary conversation and counts; a delegated subagent does not.
async function threadForRoot(flags) {
  const rootPath = need(flags, "root");
  if (!path.isAbsolute(rootPath)) usage("--root must be an absolute path");
  const { session } = await verifiedSession(flags);
  const project = await projectForRoot(session, rootPath);
  if (!project) throw new Refusal("no_thread", `T3 has no project rooted at ${rootPath}`, 5);
  const live = [];
  for (const item of await listThreads(session, project.id, ACTIVE_STATUSES)) {
    if (item.relationshipToParent === "subagent") continue;
    const t = threadOf(await session.call("t3_thread_read", { threadId: item.threadId, limit: 1, runLimit: 1 }));
    if (t.relationshipToParent === "subagent" || t.archived === true || t.archivedAt || (t.worktreePath ?? null) !== null) continue;
    if (ACTIVE_STATUSES.includes(t.status)) live.push(item.threadId);
  }
  if (live.length === 1) return { ok: true, threadId: live[0] };
  if (live.length === 0) throw new Refusal("no_thread", `no live T3 thread runs in ${rootPath}`, 5);
  throw new Refusal("ambiguous_thread", `${live.length} live T3 threads run in ${rootPath} (${live.join(", ")}); set FM_SUPERVISOR_TARGET to the captain thread id`, 6, { threadIds: live });
}

const VERBS = {
  login,
  status,
  state,
  "project-ensure": projectEnsure,
  "project-read": projectRead,
  "resolve-selection": resolveSelection,
  launch,
  send,
  read,
  capture,
  wait,
  interrupt,
  requests,
  respond,
  watch,
  archive,
  "thread-for-root": threadForRoot,
};

async function main(argv) {
  const [verb, ...rest] = argv;
  const fn = VERBS[verb];
  if (!fn) usage(`unknown verb '${verb ?? ""}' (verbs: ${Object.keys(VERBS).join(", ")})`);
  const out = await fn(parseFlags(rest));
  if (verb === "capture") process.stdout.write(`${out.text}\n`);
  else process.stdout.write(`${JSON.stringify(out)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((err) => {
    const r = err instanceof Refusal ? err : new Refusal("unexpected", err?.message ?? String(err), 1);
    process.stdout.write(`${JSON.stringify({ ok: false, error: { code: r.code, message: r.message, ...r.extra } })}\n`);
    process.stderr.write(`fm-t3-mcp: ${r.message}\n`);
    process.exit(r.exit);
  });
}
