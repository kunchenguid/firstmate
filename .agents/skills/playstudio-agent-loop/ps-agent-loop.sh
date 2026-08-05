#!/usr/bin/env bash
# ps-agent-loop.sh - drive PlayStudio agent turns via chrome-devtools-axi + BFF.
#
# Hybrid driver: Chrome attach for Entra session cookies, same-origin fetch for
# /api/entry-shell/* and /api/runs/* (never agent-host :8081, never demo-session).
#
# Usage:
#   ps-agent-loop.sh --help
#   ps-agent-loop.sh preflight
#   ps-agent-loop.sh ensureSession [--timeout-sec N]
#   ps-agent-loop.sh newProject --name NAME [--prompt TEXT] [--path scratch|reuse_engine|reskin]
#   ps-agent-loop.sh openWorkspace --url URL | --project-id ID
#   ps-agent-loop.sh sendTurn --project-id ID --prompt TEXT [--session-id ID]
#   ps-agent-loop.sh waitSettled --run-id ID --project-id ID [--timeout-sec N] [--out FILE]
#   ps-agent-loop.sh snapshotMessages --job-id ID [--out FILE]
#   ps-agent-loop.sh listCheckpoints --project-id ID --session-id ID
#   ps-agent-loop.sh revertMessage --project-id ID --session-id ID --assistant-message-id ID
#   ps-agent-loop.sh undoRestore --project-id ID --undo-token TOKEN
#   ps-agent-loop.sh fixture-blackjack [--out-dir DIR] [--timeout-sec N]
#
# Environment:
#   PS_BASE_URL                 default http://localhost:3000
#   PS_AGENT_HOST_HEALTH_URL    default http://127.0.0.1:8081/health (preflight only)
#   CHROME_DEVTOOLS_AXI_*       attach mode; prefer AUTO_CONNECT=1 with SSO'd Chrome
#   CHROME_DEVTOOLS_AXI_SESSION default playstudio-agent-loop
#   FM_HOME                     artifact default under $FM_HOME/data/playstudio-agent-loop/
#
# Exit codes: 0 ok, 1 usage/error, 2 blocked (auth/stack), 3 settle failed/timeout
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_BASE_URL="${PS_BASE_URL:-http://localhost:3000}"
PS_AGENT_HOST_HEALTH_URL="${PS_AGENT_HOST_HEALTH_URL:-http://127.0.0.1:8081/health}"
PS_AXI_SESSION="${CHROME_DEVTOOLS_AXI_SESSION:-playstudio-agent-loop}"
DEFAULT_SETTLE_TIMEOUT_SEC="${PS_SETTLE_TIMEOUT_SEC:-900}"
DEFAULT_SESSION_TIMEOUT_SEC="${PS_SESSION_TIMEOUT_SEC:-120}"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
}

die() {
  printf 'ps-agent-loop: %s\n' "$*" >&2
  exit 1
}

blocked() {
  printf 'ps-agent-loop: blocked: %s\n' "$*" >&2
  exit 2
}

settle_fail() {
  printf 'ps-agent-loop: settle-failed: %s\n' "$*" >&2
  exit 3
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

json_get() {
  # json_get <json> <python-expr-using-data>
  local json="$1"
  local expr="$2"
  JSON_IN="$json" python3 -c "import json,os; data=json.loads(os.environ['JSON_IN']); print($expr)"
}

artifact_root() {
  local home="${FM_HOME:-}"
  if [ -z "$home" ]; then
    # Prefer the captain home when this worktree is a firstmate clone/worktree.
    if [ -d /Users/b.elcelik/projects/firstmate/data ]; then
      home=/Users/b.elcelik/projects/firstmate
    else
      home="${SELF_DIR}/../../../.."
      home="$(cd "$home" 2>/dev/null && pwd || true)"
    fi
  fi
  if [ -n "${home:-}" ] && [ -d "$home" ]; then
    printf '%s/data/playstudio-agent-loop\n' "$home"
  else
    printf '%s/artifacts/playstudio-agent-loop\n' "$SELF_DIR"
  fi
}

ps_axi() {
  # Prefer auto-connect to the captain's SSO'd Chrome when no attach mode is set.
  if [ -z "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT+x}" ] \
    && [ -z "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" ] \
    && [ -z "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR:-}" ]; then
    export CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1
  fi
  export CHROME_DEVTOOLS_AXI_SESSION="$PS_AXI_SESSION"
  chrome-devtools-axi "$@"
}

ps_axi_try() {
  local out rc=0
  out="$(ps_axi "$@" 2>&1)" && { printf '%s\n' "$out"; return 0; } || rc=$?
  # Fall back once: auto-connect often fails when remote debugging is off.
  if [ "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}" = "1" ] \
    && [ -z "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" ] \
    && [ -z "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR:-}" ]; then
    # Keep the variable set (empty) so ps_axi does not re-enable auto-connect.
    export CHROME_DEVTOOLS_AXI_AUTO_CONNECT=
    export CHROME_DEVTOOLS_AXI_HEADED="${CHROME_DEVTOOLS_AXI_HEADED:-1}"
    ps_axi "$@"
    return $?
  fi
  printf '%s\n' "$out" >&2
  return "$rc"
}

axi_eval_raw() {
  local js="$1"
  local out
  out="$(ps_axi_try eval "$js" 2>&1)" || {
    printf '%s\n' "$out" >&2
    return 1
  }
  # chrome-devtools-axi prints result: "<json-escaped string>" plus help lines.
  # Page helpers often return JSON.stringify(...), which can be double-encoded.
  printf '%s\n' "$out" | python3 -c '
import json, re, sys
text = sys.stdin.read()
m = re.search(r"^result:\s*(.*)$", text, re.M)
if not m:
    sys.stderr.write("ps-agent-loop: no result: line from chrome-devtools-axi\n")
    sys.stderr.write(text)
    sys.exit(1)
raw = m.group(1).strip()
try:
    val = json.loads(raw)
except Exception:
    val = raw
for _ in range(4):
    if not isinstance(val, str):
        break
    s = val.strip()
    if not s:
        break
    try:
        val = json.loads(s)
    except Exception:
        break
if isinstance(val, (dict, list, bool)) or val is None:
    print(json.dumps(val, separators=(",", ":")))
else:
    print(val)
'
}

ensure_origin_page() {
  local out url
  out="$(ps_axi_try pages 2>&1)" || {
    blocked "Chrome attach failed (set CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 with remote debugging, or BROWSER_URL / USER_DATA_DIR). Detail: $(printf '%s' "$out" | tr '\n' ' ')"
  }
  if printf '%s' "$out" | grep -q "Could not connect to Chrome"; then
    # pages sometimes prints the error without a non-zero exit.
    if ! out="$(ps_axi_try open "$PS_BASE_URL/home" 2>&1)"; then
      blocked "Chrome attach failed. Detail: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
  elif ! printf '%s' "$out" | grep -Eq "localhost:3000|127\.0\.0\.1:3000"; then
    ps_axi_try open "$PS_BASE_URL/home" >/dev/null
  fi
  url="$(axi_eval_raw '() => location.origin + location.pathname' || true)"
  case "$url" in
    *localhost:3000*|*127.0.0.1:3000*) ;;
    *)
      ps_axi_try open "$PS_BASE_URL/home" >/dev/null
      ;;
  esac
}

cmd_preflight() {
  require_cmd curl
  require_cmd python3
  require_cmd chrome-devtools-axi
  local web host
  web="$(curl -fsS "$PS_BASE_URL/api/healthz" || true)"
  host="$(curl -fsS "$PS_AGENT_HOST_HEALTH_URL" || true)"
  if ! printf '%s' "$web" | grep -q '"ok":true'; then
    blocked "studio-web unhealthy at $PS_BASE_URL/api/healthz - restart PlayStudio local stack (primary checkout), then retry"
  fi
  if ! printf '%s' "$host" | grep -q '"status":"ok"'; then
    blocked "agent-host unhealthy at $PS_AGENT_HOST_HEALTH_URL - restart PlayStudio agent-host on :8081, then retry"
  fi
  printf '{"ok":true,"studioWeb":%s,"agentHostStatus":"ok"}\n' "$(printf '%s' "$web" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)))')"
}

cmd_ensure_session() {
  local timeout_sec="$DEFAULT_SESSION_TIMEOUT_SEC"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      *) die "ensureSession: unknown arg: $1" ;;
    esac
  done
  ensure_origin_page
  local deadline now payload auth
  deadline=$(( $(date +%s) + timeout_sec ))
  while true; do
    payload="$(axi_eval_raw '() => fetch("/api/entry-shell/session").then(r => r.json()).then(j => JSON.stringify(j))')"
    auth="$(json_get "$payload" 'str(data.get("authenticated")).lower()')"
    if [ "$auth" = "true" ]; then
      printf '%s\n' "$payload"
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      blocked "entry-shell session not authenticated after ${timeout_sec}s - complete Entra SSO in the attached Chrome (never password/demo-session), then retry ensureSession"
    fi
    # Nudge toward sign-in without inventing credentials.
    axi_eval_raw '() => { if (!location.pathname.startsWith("/sign-in") && !location.pathname.startsWith("/auth")) { location.href="/sign-in?next=/home"; } return location.href; }' >/dev/null || true
    sleep 2
  done
}

cmd_new_project() {
  local name="" prompt="" path="scratch"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      *) die "newProject: unknown arg: $1" ;;
    esac
  done
  [ -n "$name" ] || die "newProject: --name required"
  ensure_origin_page
  local body js payload
  body="$(NAME="$name" PROMPT="$prompt" PATH_KIND="$path" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["NAME"],
  "prompt": os.environ.get("PROMPT") or None,
  "path": os.environ.get("PATH_KIND") or "scratch",
}, separators=(",", ":")))
' | python3 -c '
import json,sys
o=json.load(sys.stdin)
if o.get("prompt") is None:
  del o["prompt"]
print(json.dumps(o, separators=(",", ":")))
')"
  js="$(BODY="$body" python3 -c '
import json, os
body = json.loads(os.environ["BODY"])
print("""() => fetch("/api/entry-shell/projects", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(%s)}).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps(body),))
')"
  payload="$(axi_eval_raw "$js")"
  local status
  status="$(json_get "$payload" 'data["status"]')"
  if [ "$status" != "201" ]; then
    die "newProject failed: $payload"
  fi
  json_get "$payload" 'json.dumps(data["body"], separators=(",", ":"))'
}

cmd_open_workspace() {
  local url="" project_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      --project-id) project_id="$2"; shift 2 ;;
      *) die "openWorkspace: unknown arg: $1" ;;
    esac
  done
  if [ -z "$url" ] && [ -n "$project_id" ]; then
    url="/workspace/$project_id"
  fi
  [ -n "$url" ] || die "openWorkspace: --url or --project-id required"
  case "$url" in
    http://*|https://*) ;;
    /*) url="${PS_BASE_URL}${url}" ;;
    *) url="${PS_BASE_URL}/${url}" ;;
  esac
  ensure_origin_page
  ps_axi_try open "$url" >/dev/null
  # Optional chat registration when project id known.
  if [ -n "$project_id" ]; then
    local js
    js="$(PROJECT_ID="$project_id" python3 -c '
import json, os
pid = os.environ["PROJECT_ID"]
print("""() => fetch("/api/runs/session", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(%s)}).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps({"projectId": pid}),))
')"
    axi_eval_raw "$js" || true
  fi
  printf '{"ok":true,"workspaceUrl":%s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$url")"
}

cmd_send_turn() {
  local project_id="" prompt="" session_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      *) die "sendTurn: unknown arg: $1" ;;
    esac
  done
  [ -n "$project_id" ] || die "sendTurn: --project-id required"
  [ -n "$prompt" ] || die "sendTurn: --prompt required"
  ensure_origin_page
  local js payload status
  js="$(PROJECT_ID="$project_id" PROMPT="$prompt" SESSION_ID="$session_id" python3 -c '
import json, os
body = {"projectId": os.environ["PROJECT_ID"], "prompt": os.environ["PROMPT"]}
sid = os.environ.get("SESSION_ID") or ""
if sid:
  body["sessionId"] = sid
print("""() => fetch("/api/runs/start", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(%s)}).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps(body),))
')"
  payload="$(axi_eval_raw "$js")"
  status="$(json_get "$payload" 'data["status"]')"
  if [ "$status" != "200" ]; then
    die "sendTurn failed: $payload"
  fi
  json_get "$payload" 'json.dumps(data["body"], separators=(",", ":"))'
}

# Start SSE consumption in-page (async job) so axi eval is not held for the whole turn.
_start_wait_job() {
  local run_id="$1"
  local project_id="$2"
  local timeout_sec="$3"
  local js
  js="$(RUN_ID="$run_id" PROJECT_ID="$project_id" TIMEOUT_SEC="$timeout_sec" python3 -c '
import json, os
run_id = os.environ["RUN_ID"]
project_id = os.environ["PROJECT_ID"]
timeout_ms = int(os.environ["TIMEOUT_SEC"]) * 1000
print("""() => {
  const runId = %s;
  const projectId = %s;
  const timeoutMs = %d;
  window.__psAgentLoopJobs = window.__psAgentLoopJobs || {};
  const jobId = "job_" + Date.now() + "_" + Math.random().toString(36).slice(2, 8);
  const frames = [];
  const startedAt = Date.now();
  window.__psAgentLoopJobs[jobId] = { status: "running", runId, projectId, frames: [], startedAt };
  (async () => {
    try {
      const url = "/api/runs/" + encodeURIComponent(runId) + "/stream?projectId=" + encodeURIComponent(projectId);
      const res = await fetch(url);
      if (!res.ok) {
        window.__psAgentLoopJobs[jobId] = { status: "error", error: "stream_http_" + res.status, frames, runId, projectId };
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (true) {
        if (Date.now() - startedAt > timeoutMs) {
          window.__psAgentLoopJobs[jobId] = { status: "timeout", frames, runId, projectId, lastRunEventSeq: frames.reduce((m,f)=>Math.max(m, f.runEventSeq||0), 0) };
          try { reader.cancel(); } catch (_) {}
          return;
        }
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true });
        const parts = buffer.split("\\n\\n");
        buffer = parts.pop() || "";
        for (const part of parts) {
          const dataLine = part.split("\\n").find((l) => l.startsWith("data: "));
          if (!dataLine) continue;
          let parsed;
          try { parsed = JSON.parse(dataLine.slice(6)); } catch (_) { continue; }
          frames.push(parsed);
          const t = parsed && parsed.part && parsed.part.type;
          if (t === "done" || t === "error") {
            window.__psAgentLoopJobs[jobId] = {
              status: "settled",
              settledType: t,
              partStatus: (parsed.part && parsed.part.status) || null,
              frames,
              runId,
              projectId,
              sessionId: parsed.sessionId || null,
              lastRunEventSeq: frames.reduce((m,f)=>Math.max(m, f.runEventSeq||0), 0),
            };
            return;
          }
        }
      }
      window.__psAgentLoopJobs[jobId] = { status: "stream_closed", frames, runId, projectId };
    } catch (err) {
      window.__psAgentLoopJobs[jobId] = { status: "error", error: String(err && err.message || err), frames, runId, projectId };
    }
  })();
  return JSON.stringify({ jobId, started: true, runId, projectId });
}""" % (json.dumps(run_id), json.dumps(project_id), timeout_ms))
')"
  axi_eval_raw "$js"
}

_poll_wait_job() {
  local job_id="$1"
  local timeout_sec="$2"
  local deadline now payload status js
  deadline=$(( $(date +%s) + timeout_sec + 5 ))
  js="$(python3 -c 'import json,sys; print("""() => JSON.stringify((window.__psAgentLoopJobs && window.__psAgentLoopJobs[%s]) || {status:\"missing\"})""" % (json.dumps(sys.argv[1]),))' "$job_id")"
  while true; do
    payload="$(axi_eval_raw "$js")"
    status="$(json_get "$payload" 'data.get("status")')"
    case "$status" in
      settled|timeout|error|stream_closed|missing)
        printf '%s\n' "$payload"
        return 0
        ;;
    esac
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      settle_fail "waitSettled poll deadline for job $job_id"
    fi
    sleep 2
  done
}

cmd_wait_settled() {
  local run_id="" project_id="" timeout_sec="$DEFAULT_SETTLE_TIMEOUT_SEC" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) run_id="$2"; shift 2 ;;
      --project-id) project_id="$2"; shift 2 ;;
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) die "waitSettled: unknown arg: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "waitSettled: --run-id required"
  [ -n "$project_id" ] || die "waitSettled: --project-id required"
  ensure_origin_page
  local started job_id payload status
  started="$(_start_wait_job "$run_id" "$project_id" "$timeout_sec")"
  job_id="$(json_get "$started" 'data.get("jobId")')"
  [ -n "$job_id" ] && [ "$job_id" != "None" ] || die "waitSettled: failed to start stream job: $started"
  payload="$(_poll_wait_job "$job_id" "$timeout_sec")"
  # Attach jobId so snapshotMessages can reload frames from the page job.
  payload="$(JOB_ID="$job_id" PAYLOAD="$payload" python3 -c 'import json,os; d=json.loads(os.environ["PAYLOAD"]); d["jobId"]=os.environ["JOB_ID"]; print(json.dumps(d, separators=(",", ":")))')"
  status="$(json_get "$payload" 'data.get("status")')"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$payload" >"$out"
  fi
  case "$status" in
    settled)
      settled_type="$(json_get "$payload" 'data.get("settledType")')"
      if [ "$settled_type" = "error" ]; then
        if [ -n "$out" ]; then
          mkdir -p "$(dirname "$out")"
          printf '%s\n' "$payload" >"$out"
        fi
        settle_fail "SSE error frame for run $run_id: $payload"
      fi
      printf '%s\n' "$payload"
      ;;
    timeout)
      settle_fail "SSE timeout after ${timeout_sec}s for run $run_id"
      ;;
    *)
      settle_fail "SSE did not settle ($status) for run $run_id: $payload"
      ;;
  esac
}

cmd_snapshot_messages() {
  local job_id="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --job-id) job_id="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) die "snapshotMessages: unknown arg: $1" ;;
    esac
  done
  [ -n "$job_id" ] || die "snapshotMessages: --job-id required (from waitSettled / in-page job; no list API)"
  ensure_origin_page
  local payload
  payload="$(axi_eval_raw "() => JSON.stringify((window.__psAgentLoopJobs && window.__psAgentLoopJobs[$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$job_id")]) || {status:\"missing\"})")"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$payload" >"$out"
  fi
  printf '%s\n' "$payload"
}

cmd_list_checkpoints() {
  local project_id="" session_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      *) die "listCheckpoints: unknown arg: $1" ;;
    esac
  done
  [ -n "$project_id" ] || die "listCheckpoints: --project-id required"
  [ -n "$session_id" ] || die "listCheckpoints: --session-id required"
  ensure_origin_page
  local js
  js="$(PROJECT_ID="$project_id" SESSION_ID="$session_id" python3 -c '
import json, os
q = "projectId=" + os.environ["PROJECT_ID"] + "&sessionId=" + os.environ["SESSION_ID"]
print("""() => fetch("/api/runs/history?" + %s).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps(q),))
')"
  axi_eval_raw "$js"
}

cmd_revert_message() {
  local project_id="" session_id="" assistant_message_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      --assistant-message-id) assistant_message_id="$2"; shift 2 ;;
      *) die "revertMessage: unknown arg: $1" ;;
    esac
  done
  [ -n "$project_id" ] || die "revertMessage: --project-id required"
  [ -n "$session_id" ] || die "revertMessage: --session-id required"
  [ -n "$assistant_message_id" ] || die "revertMessage: --assistant-message-id required"
  ensure_origin_page
  local js
  js="$(python3 -c '
import json, os, sys
body = {
  "projectId": sys.argv[1],
  "sessionId": sys.argv[2],
  "assistantMessageId": sys.argv[3],
  "mode": "revert",
}
print("""() => fetch("/api/runs/restore", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(%s)}).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps(body),))
' "$project_id" "$session_id" "$assistant_message_id")"
  axi_eval_raw "$js"
}

cmd_undo_restore() {
  local project_id="" undo_token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --undo-token) undo_token="$2"; shift 2 ;;
      *) die "undoRestore: unknown arg: $1" ;;
    esac
  done
  [ -n "$project_id" ] || die "undoRestore: --project-id required"
  [ -n "$undo_token" ] || die "undoRestore: --undo-token required"
  ensure_origin_page
  local js
  js="$(python3 -c '
import json, sys
body = {"projectId": sys.argv[1], "undoToken": sys.argv[2]}
print("""() => fetch("/api/runs/restore/undo", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(%s)}).then(async r => JSON.stringify({status:r.status, body:await r.json()}))""" % (json.dumps(body),))
' "$project_id" "$undo_token")"
  axi_eval_raw "$js"
}

cmd_fixture_blackjack() {
  local out_dir="" timeout_sec="$DEFAULT_SETTLE_TIMEOUT_SEC"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-dir) out_dir="$2"; shift 2 ;;
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      *) die "fixture-blackjack: unknown arg: $1" ;;
    esac
  done
  if [ -z "$out_dir" ]; then
    out_dir="$(artifact_root)/blackjack-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mkdir -p "$out_dir"
  require_cmd curl
  cmd_preflight >"$out_dir/preflight.json"
  cmd_ensure_session --timeout-sec "$DEFAULT_SESSION_TIMEOUT_SEC" >"$out_dir/session.json"

  local create_prompt project_name create_json project_id workspace_url
  project_name="fm-blackjack-fixture-$(date -u +%Y%m%d%H%M%S)"
  create_prompt='Build a simple single-player blackjack game with a clear How to Play section. Use a clean layout, deal/hit/stand controls, and show the player and dealer hands with running totals. Keep scope small and playable in the browser.'
  create_json="$(cmd_new_project --name "$project_name" --prompt "$create_prompt" --path scratch)"
  printf '%s\n' "$create_json" >"$out_dir/project.json"
  project_id="$(json_get "$create_json" 'data["project"]["id"]')"
  workspace_url="$(json_get "$create_json" 'data.get("workspaceUrl") or ""')"
  [ -n "$project_id" ] && [ "$project_id" != "None" ] || die "fixture: missing project id: $create_json"

  if [ -n "$workspace_url" ] && [ "$workspace_url" != "None" ]; then
    cmd_open_workspace --url "$workspace_url" --project-id "$project_id" >"$out_dir/workspace.json"
  else
    cmd_open_workspace --project-id "$project_id" >"$out_dir/workspace.json"
  fi

  local transcript="$out_dir/transcript.jsonl"
  : >"$transcript"
  local session_id="" turn_idx=0

  run_one_turn() {
    local prompt="$1"
    local label="$2"
    turn_idx=$((turn_idx + 1))
    local start_json run_id settle_json
    if [ -n "$session_id" ]; then
      start_json="$(cmd_send_turn --project-id "$project_id" --prompt "$prompt" --session-id "$session_id")"
    else
      start_json="$(cmd_send_turn --project-id "$project_id" --prompt "$prompt")"
    fi
    printf '%s\n' "$start_json" >"$out_dir/turn-${turn_idx}-start.json"
    run_id="$(json_get "$start_json" 'data.get("runId")')"
    session_id="$(json_get "$start_json" 'data.get("sessionId")')"
    [ -n "$run_id" ] && [ "$run_id" != "None" ] || die "fixture: missing runId on $label"
    settle_json="$(cmd_wait_settled --run-id "$run_id" --project-id "$project_id" --timeout-sec "$timeout_sec" --out "$out_dir/turn-${turn_idx}-settle.json")"
    TURN_IDX="$turn_idx" LABEL="$label" RUN_ID="$run_id" SESSION_ID="$session_id" PROJECT_ID="$project_id" \
      SETTLE="$settle_json" START="$start_json" python3 -c '
import json, os
rec = {
  "turn": int(os.environ["TURN_IDX"]),
  "label": os.environ["LABEL"],
  "projectId": os.environ["PROJECT_ID"],
  "sessionId": os.environ["SESSION_ID"],
  "runId": os.environ["RUN_ID"],
  "start": json.loads(os.environ["START"]),
  "settle": json.loads(os.environ["SETTLE"]),
}
print(json.dumps(rec, separators=(",", ":")))
' >>"$transcript"
  }

  # Base create prompt already started agent work via project create in some flows;
  # still send an explicit first workspace turn for a durable session + SSE transcript.
  run_one_turn "$create_prompt" "base-blackjack"
  run_one_turn "Add a Double Down action that is available on the player's first two cards when the rules allow it, and update How to Play to mention it." "feature-double-down"
  run_one_turn "Add a simple Stats page or panel showing hands played, wins, losses, and busts for this session." "feature-stats"
  run_one_turn "Apply a restrained dark casino theme with clear contrast for cards and controls; keep text readable." "feature-theme"

  SUMMARY_PATH="$out_dir/summary.json" PROJECT_ID="$project_id" SESSION_ID="$session_id" \
    PROJECT_NAME="$project_name" WORKSPACE_URL="$workspace_url" TRANSCRIPT="$transcript" \
    python3 -c '
import json, os
summary = {
  "ok": True,
  "projectId": os.environ["PROJECT_ID"],
  "projectName": os.environ["PROJECT_NAME"],
  "sessionId": os.environ["SESSION_ID"],
  "workspaceUrl": os.environ.get("WORKSPACE_URL") or None,
  "transcript": os.environ["TRANSCRIPT"],
  "turns": 4,
  "note": "SSE frames captured per turn in transcript.jsonl settle.frames; no message list API.",
}
open(os.environ["SUMMARY_PATH"], "w", encoding="utf-8").write(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, separators=(",", ":")))
'
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    preflight) shift; cmd_preflight "$@" ;;
    ensureSession) shift; cmd_ensure_session "$@" ;;
    newProject) shift; cmd_new_project "$@" ;;
    openWorkspace) shift; cmd_open_workspace "$@" ;;
    sendTurn) shift; cmd_send_turn "$@" ;;
    waitSettled) shift; cmd_wait_settled "$@" ;;
    snapshotMessages) shift; cmd_snapshot_messages "$@" ;;
    listCheckpoints) shift; cmd_list_checkpoints "$@" ;;
    revertMessage) shift; cmd_revert_message "$@" ;;
    undoRestore) shift; cmd_undo_restore "$@" ;;
    fixture-blackjack) shift; cmd_fixture_blackjack "$@" ;;
    *) die "unknown verb: $1 (see --help)" ;;
  esac
}

main "$@"
