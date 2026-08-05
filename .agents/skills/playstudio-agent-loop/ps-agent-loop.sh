#!/usr/bin/env bash
# ps-agent-loop.sh - drive PlayStudio agent turns via chrome-devtools-axi + BFF.
#
# Hybrid driver: Chrome attach for Entra session cookies, same-origin fetch for
# /api/entry-shell/* and /api/runs/* (never agent-host :8081, never demo-session).
#
# Usage:
#   ps-agent-loop.sh --help
#   ps-agent-loop.sh preflight
#   ps-agent-loop.sh ensureSession [--timeout-sec N]   # clicks Entra; blocks only on MFA/passkey
#   ps-agent-loop.sh newProject --name NAME [--prompt TEXT] [--path scratch|reuse_engine|reskin]
#   ps-agent-loop.sh openWorkspace --url URL | --project-id ID
#   ps-agent-loop.sh sendTurn --project-id ID --prompt TEXT [--session-id ID]
#   ps-agent-loop.sh waitSettled --run-id ID --project-id ID [--timeout-sec N] [--out FILE] [--review-dir DIR]
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
#   PS_REVIEW_INTERVAL_SEC      screenshot cadence while waiting (default 5)
#   PS_PLAYSTUDIO_ROOT          PlayStudio checkout for Daytona env files (optional)
#   DAYTONA_API_URL/KEY/ORG_ID  Daytona capacity gate creds (or PLAY_STUDIO_DAYTONA_*)
#   PS_DAYTONA_ORG_MEM_GIB      org memory ceiling GiB (default 10)
#   PS_DAYTONA_NEED_MEM_GIB     headroom required for one create (default 8)
#   PS_DAYTONA_PRUNE_STARTED=1  optional: DELETE started sandboxes when gate fails
#
# Review video: during waitSettled with --review-dir, capture periodic viewport
# JPEGs; fixture stitches them with ffmpeg to <out-dir>/review.mp4.
# waitSettled axi poll returns a slim status object only (never frames[]).
#
# Exit codes: 0 ok, 1 usage/error, 2 blocked (auth/stack/capacity/axi), 3 settle failed/timeout
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_BASE_URL="${PS_BASE_URL:-http://localhost:3000}"
PS_AGENT_HOST_HEALTH_URL="${PS_AGENT_HOST_HEALTH_URL:-http://127.0.0.1:8081/health}"
PS_AXI_SESSION="${CHROME_DEVTOOLS_AXI_SESSION:-playstudio-agent-loop}"
DEFAULT_SETTLE_TIMEOUT_SEC="${PS_SETTLE_TIMEOUT_SEC:-900}"
DEFAULT_SESSION_TIMEOUT_SEC="${PS_SESSION_TIMEOUT_SEC:-120}"
REVIEW_INTERVAL_SEC="${PS_REVIEW_INTERVAL_SEC:-5}"
PS_DAYTONA_ORG_MEM_GIB="${PS_DAYTONA_ORG_MEM_GIB:-10}"
PS_DAYTONA_NEED_MEM_GIB="${PS_DAYTONA_NEED_MEM_GIB:-8}"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
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

# Tolerant JSON load for SSE/agent frames that embed raw control characters.
# Empty or unrecoverable payloads exit 2 with a one-line blocked message (no traceback).
_py_loads_tolerant() {
  python3 -c '
import json, os, re, sys

def loads_tolerant(text):
    if text is None:
        raise ValueError("empty")
    raw = text if isinstance(text, str) else str(text)
    if not raw.strip():
        raise ValueError("empty")
    try:
        return json.loads(raw, strict=False)
    except json.JSONDecodeError:
        pass
    # Drop illegal controls outside JSON string escapes; keep tab/LF/CR.
    cleaned = "".join(
        ch if (ord(ch) >= 32 or ch in "\t\n\r") else " "
        for ch in raw
    )
    cleaned = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", " ", cleaned)
    return json.loads(cleaned, strict=False)

mode = os.environ.get("PS_JSON_MODE", "get")
try:
    if mode == "get":
        data = loads_tolerant(os.environ.get("JSON_IN", ""))
        expr = os.environ["JSON_EXPR"]
        print(eval(expr, {"json": json, "data": data}))  # noqa: S307 - caller-owned expr
    elif mode == "loads":
        data = loads_tolerant(sys.stdin.read())
        print(json.dumps(data, separators=(",", ":")))
    elif mode == "axi-unwrap":
        text = sys.stdin.read()
        m = re.search(r"^result:\s*(.*)$", text, re.M)
        if not m:
            raise ValueError("no result: line from chrome-devtools-axi")
        raw = m.group(1).strip()
        if not raw:
            raise ValueError("empty axi result")
        try:
            val = loads_tolerant(raw)
        except Exception:
            val = raw
        for _ in range(4):
            if not isinstance(val, str):
                break
            s = val.strip()
            if not s:
                break
            try:
                val = loads_tolerant(s)
            except Exception:
                break
        if isinstance(val, (dict, list, bool)) or val is None:
            print(json.dumps(val, separators=(",", ":")))
        else:
            print(val)
    else:
        raise ValueError("unknown PS_JSON_MODE")
except Exception as exc:
    sys.stderr.write("ps-agent-loop: blocked: invalid or empty JSON/axi payload (%s)\n" % (exc,))
    sys.exit(2)
'
}

json_get() {
  # json_get <json> <python-expr-using-data>
  local json="$1"
  local expr="$2"
  local out rc=0
  out="$(PS_JSON_MODE=get JSON_IN="$json" JSON_EXPR="$expr" _py_loads_tolerant)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 2
  fi
  printf '%s\n' "$out"
}

json_loads_stdout() {
  # Read stdin JSON (tolerant) → compact JSON stdout; exit 2 on failure.
  local out rc=0
  out="$(PS_JSON_MODE=loads _py_loads_tolerant)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 2
  fi
  printf '%s\n' "$out"
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
  local out rc=0
  out="$(ps_axi_try eval "$js" 2>&1)" || {
    printf '%s\n' "$out" >&2
    return 1
  }
  # chrome-devtools-axi prints result: "<json-escaped string>" plus help lines.
  # Page helpers often return JSON.stringify(...), which can be double-encoded.
  # SSE/agent frames may embed raw control characters - unwrap with a tolerant decoder.
  printf '%s\n' "$out" | PS_JSON_MODE=axi-unwrap _py_loads_tolerant || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 2
  fi
  return 0
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
  local web host daytona_json
  web="$(curl -fsS "$PS_BASE_URL/api/healthz" || true)"
  host="$(curl -fsS "$PS_AGENT_HOST_HEALTH_URL" || true)"
  if ! printf '%s' "$web" | grep -q '"ok":true'; then
    blocked "studio-web unhealthy at $PS_BASE_URL/api/healthz - restart PlayStudio local stack (primary checkout), then retry"
  fi
  if ! printf '%s' "$host" | grep -q '"status":"ok"'; then
    blocked "agent-host unhealthy at $PS_AGENT_HOST_HEALTH_URL - restart PlayStudio agent-host on :8081, then retry"
  fi
  daytona_json="$(_daytona_capacity_gate)"
  printf '{"ok":true,"studioWeb":%s,"agentHostStatus":"ok","daytona":%s}\n' \
    "$(printf '%s' "$web" | PS_JSON_MODE=loads _py_loads_tolerant)" \
    "$daytona_json"
}

# Ensure Daytona org memory has headroom for one create: started_mem + need ≤ org_cap.
# Creds from env (DAYTONA_* / PLAY_STUDIO_DAYTONA_*) or PlayStudio .env.runtime.local / .env.local.
# Optional PS_DAYTONA_PRUNE_STARTED=1 deletes started sandboxes once, then rechecks.
_daytona_capacity_gate() {
  local root="${PS_PLAYSTUDIO_ROOT:-}"
  if [ -z "$root" ] && [ -n "${HOME:-}" ] && [ -d "$HOME/projects/PlayStudio" ]; then
    root="$HOME/projects/PlayStudio"
  fi
  PS_DAYTONA_ORG_MEM_GIB="$PS_DAYTONA_ORG_MEM_GIB" \
  PS_DAYTONA_NEED_MEM_GIB="$PS_DAYTONA_NEED_MEM_GIB" \
  PS_DAYTONA_PRUNE_STARTED="${PS_DAYTONA_PRUNE_STARTED:-}" \
  PS_PLAYSTUDIO_ROOT="$root" \
  python3 -c '
import json, os, sys, urllib.error, urllib.request

ORG = float(os.environ.get("PS_DAYTONA_ORG_MEM_GIB") or "10")
NEED = float(os.environ.get("PS_DAYTONA_NEED_MEM_GIB") or "8")
PRUNE = (os.environ.get("PS_DAYTONA_PRUNE_STARTED") or "").strip() == "1"
ROOT = (os.environ.get("PS_PLAYSTUDIO_ROOT") or "").strip()

def load_env_file(path, env):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k, v = k.strip(), v.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        if not k.startswith(("DAYTONA_", "PLAY_STUDIO_DAYTONA_")):
            continue
        env.setdefault(k, v)

env = dict(os.environ)
if ROOT:
    for name in (".env.runtime.local", ".env.local"):
        load_env_file(os.path.join(ROOT, name), env)

api_url = (env.get("DAYTONA_API_URL") or env.get("PLAY_STUDIO_DAYTONA_API_URL") or "").strip().rstrip("/")
api_key = (env.get("DAYTONA_API_KEY") or env.get("PLAY_STUDIO_DAYTONA_API_KEY") or "").strip()
org_id = (env.get("DAYTONA_ORG_ID") or env.get("PLAY_STUDIO_DAYTONA_ORGANIZATION_ID") or "").strip()

if not api_url or not api_key:
    sys.stderr.write(
        "ps-agent-loop: blocked: Daytona capacity gate missing DAYTONA_API_URL/KEY "
        "(set env or PS_PLAYSTUDIO_ROOT to a checkout with .env.runtime.local)\n"
    )
    sys.exit(2)

headers = {"Authorization": "Bearer " + api_key, "Accept": "application/json"}
if org_id:
    headers["X-Daytona-Organization-ID"] = org_id

def call(path, method="GET"):
    req = urllib.request.Request(api_url + path, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(body) if body.strip() else None
        except Exception:
            payload = body[:200]
        return exc.code, payload
    except Exception as exc:
        sys.stderr.write("ps-agent-loop: blocked: Daytona API error (%s)\n" % (exc,))
        sys.exit(2)

def list_sandboxes():
    status, payload = call("/sandbox")
    if status != 200:
        sys.stderr.write("ps-agent-loop: blocked: Daytona list sandboxes HTTP %s\n" % (status,))
        sys.exit(2)
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        items = payload.get("items")
        if isinstance(items, list):
            return items
    return []

def state_of(s):
    return str(s.get("state") or s.get("status") or "unknown").lower()

def mem_of(s):
    for key in ("memory", "memoryGib", "mem"):
        if key in s and s[key] is not None:
            try:
                return float(s[key])
            except (TypeError, ValueError):
                pass
    res = s.get("resources") if isinstance(s.get("resources"), dict) else {}
    for key in ("memory", "memoryGib"):
        if key in res and res[key] is not None:
            try:
                return float(res[key])
            except (TypeError, ValueError):
                pass
    return 0.0

def started_mem(sandboxes):
    started = [s for s in sandboxes if state_of(s) == "started"]
    total = sum(mem_of(s) for s in started)
    return started, total

sandboxes = list_sandboxes()
started, total = started_mem(sandboxes)
pruned = []
if total + NEED > ORG:
    if not PRUNE:
        sys.stderr.write(
            "ps-agent-loop: blocked: Daytona started_mem %.1fGiB + need %.1fGiB > org %.1fGiB "
            "(%d started); free capacity or set PS_DAYTONA_PRUNE_STARTED=1\n"
            % (total, NEED, ORG, len(started))
        )
        sys.exit(2)
    for s in started:
        sid = str(s.get("id") or "")
        if not sid:
            continue
        # Stop first when needed; delete releases memory reservation.
        st, _ = call("/sandbox/%s/stop" % sid, method="POST")
        st2, _ = call("/sandbox/%s" % sid, method="DELETE")
        pruned.append({"id": sid, "stopStatus": st, "deleteStatus": st2})
    sandboxes = list_sandboxes()
    started, total = started_mem(sandboxes)
    if total + NEED > ORG:
        sys.stderr.write(
            "ps-agent-loop: blocked: Daytona still short after prune "
            "(started_mem %.1fGiB + need %.1fGiB > org %.1fGiB)\n"
            % (total, NEED, ORG)
        )
        sys.exit(2)

out = {
    "ok": True,
    "orgMemGib": ORG,
    "needMemGib": NEED,
    "startedCount": len(started),
    "startedMemGib": total,
    "headroomGib": ORG - total,
    "pruned": pruned,
}
print(json.dumps(out, separators=(",", ":")))
'
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
  local deadline now payload auth clicked=0 mfa
  deadline=$(( $(date +%s) + timeout_sec ))
  while true; do
    payload="$(axi_eval_raw '() => fetch("/api/entry-shell/session").then(r => r.json()).then(j => JSON.stringify(j))')"
    auth="$(json_get "$payload" 'str(data.get("authenticated")).lower()')"
    if [ "$auth" = "true" ]; then
      printf '%s\n' "$payload"
      return 0
    fi

    # Block only when the flow actually stopped on MFA / passkey / verification.
    mfa="$(axi_eval_raw '() => {
      const t = (document.body && document.body.innerText || "").toLowerCase();
      const hits = [];
      if (/passkey|security key|touch.?id|face.?id/.test(t)) hits.push("passkey");
      if (/\bmfa\b|multi-factor|two-factor|2fa|authenticator app|enter (the )?code|verification code|approve.*(sign-?in|request)/.test(t)) hits.push("mfa");
      return JSON.stringify({ hits, href: location.href, title: document.title || "" });
    }' || echo '{"hits":[]}')"
    if [ "$(json_get "$mfa" 'len(data.get("hits") or [])')" != "0" ]; then
      blocked "Entra sign-in stopped on MFA/passkey ($(json_get "$mfa" '",".join(data.get("hits") or [])')) at $(json_get "$mfa" 'data.get("href")') - complete that challenge once, then retry ensureSession"
    fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      blocked "entry-shell session not authenticated after ${timeout_sec}s after Entra click attempt - inspect attached Chrome (never password/demo-session)"
    fi

    # Drive Entra ourselves: open sign-in and click Microsoft / Entra once.
    axi_eval_raw '() => {
      if (!location.pathname.startsWith("/sign-in") && !location.pathname.startsWith("/auth") && !/login\.microsoftonline\.com|login\.live\.com/.test(location.hostname)) {
        location.href = "/sign-in?next=/home";
      }
      return location.href;
    }' >/dev/null || true
    sleep 1
    if [ "$clicked" -eq 0 ]; then
      # Prefer axi click on a visible Entra control when snapshot exposes one.
      if ps_axi_try snapshot 2>/dev/null | grep -qiE 'Continue with Microsoft|Microsoft Entra|Entra ID'; then
        local snap_uid
        snap_uid="$(ps_axi_try snapshot 2>/dev/null | python3 -c '
import re, sys
text = sys.stdin.read()
# Match axi snapshot lines like: uid=g1:1_20 button "Continue with Microsoft Entra ID"
pat = re.compile(r"uid=(\S+)\s+button\s+\"([^\"]*(?:Microsoft|Entra)[^\"]*)\"", re.I)
for m in pat.finditer(text):
    print(m.group(1))
    raise SystemExit(0)
' || true)"
        if [ -n "${snap_uid:-}" ]; then
          ps_axi_try click "@${snap_uid}" >/dev/null || true
          clicked=1
        fi
      fi
      if [ "$clicked" -eq 0 ]; then
        local click_res
        click_res="$(axi_eval_raw '() => {
          const nodes = [...document.querySelectorAll("button, a, [role=button]")];
          const btn = nodes.find((el) => /microsoft|entra/i.test((el.textContent || el.getAttribute("aria-label") || "").trim()));
          if (!btn) return JSON.stringify({ clicked: false, reason: "entra_button_not_found" });
          btn.click();
          return JSON.stringify({ clicked: true, label: (btn.textContent || "").trim().slice(0, 80) });
        }' || echo '{"clicked":false}')"
        if [ "$(json_get "$click_res" 'str(data.get("clicked")).lower()')" = "true" ]; then
          clicked=1
        fi
      fi
    fi
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

_capture_review_frame() {
  # Best-effort viewport JPEG into <dir>/frame-NNNNNN.jpg. Never fails the turn.
  local dir="$1"
  local idx="$2"
  local path
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" || return 0
  path="$(printf '%s/frame-%06d.jpg' "$dir" "$idx")"
  ps_axi_try screenshot "$path" --format jpeg >/dev/null 2>&1 || true
}

_stitch_review_mp4() {
  # Stitch frame-*.jpg under frames_dir into out_mp4 via ffmpeg. Soft-fail if none.
  local frames_dir="$1"
  local out_mp4="$2"
  local count
  [ -d "$frames_dir" ] || return 1
  require_cmd ffmpeg
  count="$(find "$frames_dir" -maxdepth 1 -name 'frame-*.jpg' 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [ "${count:-0}" -lt 1 ]; then
    printf 'ps-agent-loop: review video skipped (no frames in %s)\n' "$frames_dir" >&2
    return 1
  fi
  # Duplicate a single frame so ffmpeg can emit a short clip.
  if [ "$count" -eq 1 ]; then
    cp "$frames_dir"/frame-*.jpg "$frames_dir/frame-000001.jpg" 2>/dev/null || true
  fi
  ffmpeg -y -hide_banner -loglevel error \
    -framerate 1 \
    -pattern_type glob -i "$frames_dir/frame-*.jpg" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    "$out_mp4"
}

# Slim job status for axi polling — NEVER stringify frames[] through chrome-devtools-axi.
_job_slim_status_js() {
  python3 -c 'import json,sys
jid=json.dumps(sys.argv[1])
print("""() => {
  const jobId = %s;
  const job = (window.__psAgentLoopJobs && window.__psAgentLoopJobs[jobId]) || { status: "missing" };
  const frames = Array.isArray(job.frames) ? job.frames : [];
  let lastSeq = job.lastRunEventSeq;
  if (lastSeq == null) {
    lastSeq = frames.reduce((m, f) => Math.max(m, (f && f.runEventSeq) || 0), 0);
  }
  return JSON.stringify({
    status: job.status || "missing",
    settledType: job.settledType || null,
    partStatus: job.partStatus || null,
    frameCount: frames.length,
    runId: job.runId || null,
    projectId: job.projectId || null,
    sessionId: job.sessionId || null,
    lastRunEventSeq: lastSeq || 0,
    error: job.error || null
  });
 }""" % (jid,))' "$1"
}

# Slim agent-visible summaries from page-local frames (frames stay on the page job).
_job_message_summaries_js() {
  python3 -c 'import json,sys
jid=json.dumps(sys.argv[1])
print("""() => {
  const jobId = %s;
  const job = (window.__psAgentLoopJobs && window.__psAgentLoopJobs[jobId]) || null;
  if (!job) return JSON.stringify({ status: "missing", frameCount: 0, messageCount: 0, messages: [] });
  const frames = Array.isArray(job.frames) ? job.frames : [];
  const messages = [];
  const MAX = 40;
  const MAX_TEXT = 240;
  const interesting = new Set(["text", "message", "assistant", "error", "done", "step", "tool", "run"]);
  for (const f of frames) {
    if (messages.length >= MAX) break;
    const part = f && f.part;
    if (!part || typeof part !== "object") continue;
    const t = part.type;
    if (!interesting.has(t)) continue;
    let text = part.text || part.message || part.label || part.content || null;
    if (text && typeof text === "object") {
      text = text.text || text.value || null;
      if (text && typeof text !== "string") text = String(text).slice(0, MAX_TEXT);
    }
    if (typeof text === "string" && text.length > MAX_TEXT) text = text.slice(0, MAX_TEXT);
    messages.push({
      seq: f.seq || f.runEventSeq || null,
      type: t,
      state: part.state || null,
      code: part.code || part.errorCode || null,
      text: text || null
    });
  }
  return JSON.stringify({
    status: job.status || null,
    settledType: job.settledType || null,
    frameCount: frames.length,
    messageCount: messages.length,
    messages: messages,
    runId: job.runId || null,
    projectId: job.projectId || null,
    sessionId: job.sessionId || null
  });
 }""" % (jid,))' "$1"
}

_poll_wait_job() {
  local job_id="$1"
  local timeout_sec="$2"
  local review_dir="${3:-}"
  local deadline now payload status js frame_idx=0 last_shot=0 rc
  deadline=$(( $(date +%s) + timeout_sec + 5 ))
  js="$(_job_slim_status_js "$job_id")"
  # Capture an opening frame immediately when review is enabled.
  if [ -n "$review_dir" ]; then
    _capture_review_frame "$review_dir" "$frame_idx"
    frame_idx=$((frame_idx + 1))
    last_shot="$(date +%s)"
  fi
  while true; do
    rc=0
    payload="$(axi_eval_raw "$js")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "${payload:-}" ]; then
      blocked "waitSettled: empty or invalid axi payload while polling job $job_id (rc=$rc)"
    fi
    rc=0
    status="$(json_get "$payload" 'data.get("status")')" || rc=$?
    if [ "$rc" -ne 0 ]; then
      exit 2
    fi
    case "$status" in
      settled|timeout|error|stream_closed|missing)
        if [ -n "$review_dir" ]; then
          _capture_review_frame "$review_dir" "$frame_idx"
        fi
        printf '%s\n' "$payload"
        return 0
        ;;
    esac
    now="$(date +%s)"
    if [ -n "$review_dir" ] && [ $((now - last_shot)) -ge "$REVIEW_INTERVAL_SEC" ]; then
      _capture_review_frame "$review_dir" "$frame_idx"
      frame_idx=$((frame_idx + 1))
      last_shot="$now"
    fi
    if [ "$now" -ge "$deadline" ]; then
      settle_fail "waitSettled poll deadline for job $job_id"
    fi
    sleep 2
  done
}

cmd_wait_settled() {
  local run_id="" project_id="" timeout_sec="$DEFAULT_SETTLE_TIMEOUT_SEC" out="" review_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) run_id="$2"; shift 2 ;;
      --project-id) project_id="$2"; shift 2 ;;
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --review-dir) review_dir="$2"; shift 2 ;;
      *) die "waitSettled: unknown arg: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "waitSettled: --run-id required"
  [ -n "$project_id" ] || die "waitSettled: --project-id required"
  ensure_origin_page
  local started job_id payload status summaries
  started="$(_start_wait_job "$run_id" "$project_id" "$timeout_sec")"
  job_id="$(json_get "$started" 'data.get("jobId")')"
  [ -n "$job_id" ] && [ "$job_id" != "None" ] || die "waitSettled: failed to start stream job: $started"
  payload="$(_poll_wait_job "$job_id" "$timeout_sec" "$review_dir")"
  # Attach jobId + slim message summaries (separate axi eval; never dump frames[]).
  summaries="$(axi_eval_raw "$(_job_message_summaries_js "$job_id")" || echo '{"messages":[]}')"
  payload="$(JOB_ID="$job_id" PAYLOAD="$payload" SUMMARIES="$summaries" python3 -c '
import json, os, re, sys

def loads_tolerant(text):
    raw = text if isinstance(text, str) else str(text)
    if not raw.strip():
        raise ValueError("empty")
    try:
        return json.loads(raw, strict=False)
    except json.JSONDecodeError:
        cleaned = "".join(ch if (ord(ch) >= 32 or ch in "\t\n\r") else " " for ch in raw)
        cleaned = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", " ", cleaned)
        return json.loads(cleaned, strict=False)

try:
    d = loads_tolerant(os.environ["PAYLOAD"])
    d["jobId"] = os.environ["JOB_ID"]
    try:
        s = loads_tolerant(os.environ.get("SUMMARIES") or "{}")
        d["messageCount"] = s.get("messageCount")
        d["messages"] = s.get("messages") or []
    except Exception:
        d["messages"] = []
    print(json.dumps(d, separators=(",", ":")))
except Exception as exc:
    sys.stderr.write("ps-agent-loop: blocked: invalid waitSettled payload (%s)\n" % (exc,))
    sys.exit(2)
')" || exit 2
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
  # Slim path only: message summaries, never the full frames[] array through axi.
  payload="$(axi_eval_raw "$(_job_message_summaries_js "$job_id")")"
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
  require_cmd ffmpeg
  local frames_dir="$out_dir/frames"
  mkdir -p "$frames_dir"
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
    local start_json run_id settle_json turn_frames
    turn_frames="$frames_dir/turn-${turn_idx}"
    mkdir -p "$turn_frames"
    if [ -n "$session_id" ]; then
      start_json="$(cmd_send_turn --project-id "$project_id" --prompt "$prompt" --session-id "$session_id")"
    else
      start_json="$(cmd_send_turn --project-id "$project_id" --prompt "$prompt")"
    fi
    printf '%s\n' "$start_json" >"$out_dir/turn-${turn_idx}-start.json"
    run_id="$(json_get "$start_json" 'data.get("runId")')"
    session_id="$(json_get "$start_json" 'data.get("sessionId")')"
    [ -n "$run_id" ] && [ "$run_id" != "None" ] || die "fixture: missing runId on $label"
    settle_json="$(cmd_wait_settled --run-id "$run_id" --project-id "$project_id" --timeout-sec "$timeout_sec" --out "$out_dir/turn-${turn_idx}-settle.json" --review-dir "$turn_frames")"
    # Flatten turn frames into the shared frames dir with a global index prefix.
    local f base
    for f in "$turn_frames"/frame-*.jpg; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      cp "$f" "$frames_dir/turn${turn_idx}-${base}"
    done
    TURN_IDX="$turn_idx" LABEL="$label" RUN_ID="$run_id" SESSION_ID="$session_id" PROJECT_ID="$project_id" \
      SETTLE="$settle_json" START="$start_json" python3 -c '
import json, os, re, sys

def loads_tolerant(text):
    raw = text if isinstance(text, str) else str(text)
    if not raw.strip():
        raise ValueError("empty")
    try:
        return json.loads(raw, strict=False)
    except json.JSONDecodeError:
        cleaned = "".join(ch if (ord(ch) >= 32 or ch in "\t\n\r") else " " for ch in raw)
        cleaned = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", " ", cleaned)
        return json.loads(cleaned, strict=False)

rec = {
  "turn": int(os.environ["TURN_IDX"]),
  "label": os.environ["LABEL"],
  "projectId": os.environ["PROJECT_ID"],
  "sessionId": os.environ["SESSION_ID"],
  "runId": os.environ["RUN_ID"],
  "start": loads_tolerant(os.environ["START"]),
  "settle": loads_tolerant(os.environ["SETTLE"]),
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

  # Build a contiguous frame-*.jpg sequence for ffmpeg from flattened turn frames.
  local stitch_dir="$frames_dir/stitch"
  mkdir -p "$stitch_dir"
  python3 - "$frames_dir" "$stitch_dir" <<'PY'
import pathlib, sys, shutil
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
files = sorted([p for p in src.glob("turn*-frame-*.jpg")] + [p for p in src.glob("frame-*.jpg") if p.parent == src])
# Prefer turn-prefixed frames only when present.
turnish = sorted(src.glob("turn*-frame-*.jpg"))
files = turnish if turnish else sorted(src.glob("frame-*.jpg"))
for i, p in enumerate(files):
    shutil.copy2(p, dst / f"frame-{i:06d}.jpg")
PY
  local review_mp4="$out_dir/review.mp4"
  if _stitch_review_mp4 "$stitch_dir" "$review_mp4"; then
    :
  else
    review_mp4=""
  fi

  SUMMARY_PATH="$out_dir/summary.json" PROJECT_ID="$project_id" SESSION_ID="$session_id" \
    PROJECT_NAME="$project_name" WORKSPACE_URL="$workspace_url" TRANSCRIPT="$transcript" \
    REVIEW_MP4="$review_mp4" OUT_DIR="$out_dir" \
    python3 -c '
import json, os
summary = {
  "ok": True,
  "projectId": os.environ["PROJECT_ID"],
  "projectName": os.environ["PROJECT_NAME"],
  "sessionId": os.environ["SESSION_ID"],
  "workspaceUrl": os.environ.get("WORKSPACE_URL") or None,
  "transcript": os.environ["TRANSCRIPT"],
  "reviewMp4": os.environ.get("REVIEW_MP4") or None,
  "artifactDir": os.environ["OUT_DIR"],
  "turns": 4,
  "note": "SSE frames in transcript.jsonl; review.mp4 is ffmpeg-stitched chrome-devtools-axi screenshots.",
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
