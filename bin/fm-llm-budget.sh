#!/usr/bin/env bash
# fm-llm-budget.sh - personal Rippling LLM-gateway budget meter.
#
# ONE owner of the cache, query, print, and refresh contract used by Pi, Claude
# Code, and any other adapter that shows remaining personal gateway budget.
# Adapters call this command; they do not restate the Datadog body, cache
# schema, or dollar arithmetic. docs/llm-budget.md is a pointer here.
#
# Print never blocks on the network. Refresh is a separate path with a
# 15-minute TTL. Last-good cache is kept across refresh failures. Cache older
# than 24 hours is marked stale in the printed line but is still shown.
#
# Cache (gitignored, under the effective FM_HOME):
#   state/llm-budget-cache.json
# Fields: version=1, source (datadog|gateway-402), email, cap, spend,
# remaining, exhausted (bool), fetched_at_unix, month_start_unix.
# Remaining is cap minus spend, clamped at 0. Over-cap spend is exhausted.
# Default cap is 2000 USD unless the 402 body supplies total, FM_LLM_BUDGET_CAP
# is set, or config/llm-budget-cap contains a positive number.
#
# Email resolution, in order: RIPPLING_EMAIL, config/rippling-email, Directory
# Services, git user.email when it is @rippling.com. Tracked code never hardcodes
# one person.
#
# Auth for Datadog, in order: DD_API_KEY+DD_APP_KEY (or DATADOG_API_KEY+
# DATADOG_APP_KEY) as DD-API-KEY / DD-APPLICATION-KEY; then a Keychain session
# at service com.rippling.firstmate.llm-budget.datadog account oauth.datadoghq.com
# (Linux: state/llm-budget-datadog-oauth.json mode 0600). `login` runs one-shot
# PKCE. Never print secrets. Never use com.rippling.ai-budget.datadog.
#
# Gateway 402 fallback: `wavecode llm-gateway get-api-key`, then
# `~/.wavecode/config/llm_gateway.json` `llm_key` (or WAVECODE_CONFIG_PATH).
# If wavecode reports the budget exhausted and no 402 body is available,
# remaining is 0 at the resolved cap.
#
# Gateway models: provider rippling-bedrock or rippling-openai (or any
# rippling-* provider), or a base URL containing llm-gateway. Non-gateway
# print/statusline output is empty.
#
# Usage:
#   fm-llm-budget.sh print [--if-gateway] [--kick-refresh]
#                          [--provider <name>] [--model <id>] [--base-url <url>]
#   fm-llm-budget.sh refresh
#   fm-llm-budget.sh login
#   fm-llm-budget.sh claude-statusline [--kick-refresh]
#   fm-llm-budget.sh install-claude
#   fm-llm-budget.sh --help
#
# Environment:
#   FM_HOME / FM_ROOT_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE
#   RIPPLING_EMAIL   FM_LLM_BUDGET_CAP   WAVECODE_CONFIG_PATH
#   DD_API_KEY DD_APP_KEY (or DATADOG_API_KEY DATADOG_APP_KEY)
#   CLAUDE_CONFIG_DIR   (install-claude; default ~/.claude)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CACHE="$STATE/llm-budget-cache.json"
LOCKDIR="$STATE/llm-budget-refresh.lock"
OAUTH_FILE="$STATE/llm-budget-datadog-oauth.json"
EMAIL_FILE="$CONFIG/rippling-email"
CAP_FILE="$CONFIG/llm-budget-cap"
TTL_SECONDS=900
STALE_SECONDS=86400
DEFAULT_CAP=2000
KEYCHAIN_SERVICE="com.rippling.firstmate.llm-budget.datadog"
KEYCHAIN_ACCOUNT="oauth.datadoghq.com"
GATEWAY_HEALTH_PATH="/providers/health"
GATEWAY_HOST_NEEDLE="llm-gateway"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
}

mkdir_state() {
  mkdir -p "$STATE" "$CONFIG"
}

path_mtime() {
  if [ ! -e "$1" ]; then
    printf '%s\n' 0
    return 0
  fi
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

now_unix() {
  python3 -c 'import time; print(int(time.time()))'
}

is_gateway() {
  local provider=${1:-} model=${2:-} base=${3:-}
  local blob
  blob=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$provider" "$model" "$base" \
    "${ANTHROPIC_BASE_URL:-}" "${OPENAI_BASE_URL:-}" "${OPENAI_API_BASE:-}")
  printf '%s\n' "$blob" | grep -qi "$GATEWAY_HOST_NEEDLE" && return 0
  provider=$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')
  case "$provider" in
    rippling-bedrock|rippling-openai|rippling-*) return 0 ;;
  esac
  model=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
  case "$model" in
    rippling-bedrock*|rippling-openai*|rippling-*) return 0 ;;
  esac
  return 1
}

kick_refresh_if_due() {
  local age mtime now
  mkdir_state
  mtime=$(path_mtime "$CACHE")
  now=$(now_unix)
  age=$((now - mtime))
  if [ -f "$CACHE" ] && [ "$age" -lt "$TTL_SECONDS" ]; then
    return 0
  fi
  (
    exec >/dev/null 2>&1
    "$SCRIPT_DIR/fm-llm-budget.sh" refresh
  ) &
}

print_from_cache() {
  need_python
  if [ ! -f "$CACHE" ]; then
    printf '%s\n' "LLM budget: …"
    return 0
  fi
  python3 - "$CACHE" "$STALE_SECONDS" <<'PY'
import json, sys, time
path, stale_after = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("LLM budget: …")
    raise SystemExit(0)
cap = float(data.get("cap") or 0)
spend = float(data.get("spend") or 0)
remaining = float(data.get("remaining") if data.get("remaining") is not None else max(0.0, cap - spend))
if remaining < 0:
    remaining = 0.0
exhausted = bool(data.get("exhausted")) or remaining <= 0 < spend or spend >= cap > 0
fetched = int(data.get("fetched_at_unix") or 0)
stale = fetched > 0 and (time.time() - fetched) > stale_after

def dollars(value):
    return f"${value:,.0f}"

line = f"LLM {dollars(remaining)} of {dollars(cap)} (mtd {dollars(spend)})"
if exhausted:
    line += " exhausted"
if stale:
    line += " stale"
print(line)
PY
}

cmd_print() {
  local if_gateway=0 kick=0 provider="" model="" base_url=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --if-gateway) if_gateway=1 ;;
      --kick-refresh) kick=1 ;;
      --provider) provider=${2:-}; shift ;;
      --model) model=${2:-}; shift ;;
      --base-url) base_url=${2:-}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown print option: $1" ;;
    esac
    shift
  done
  if [ "$if_gateway" -eq 1 ] && ! is_gateway "$provider" "$model" "$base_url"; then
    return 0
  fi
  print_from_cache
  if [ "$kick" -eq 1 ]; then
    kick_refresh_if_due
  fi
}

cmd_claude_statusline() {
  local kick=0 payload provider model
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kick-refresh) kick=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown claude-statusline option: $1" ;;
    esac
    shift
  done
  need_python
  payload=$(cat || true)
  provider=""
  model=""
  if [ -n "$payload" ]; then
    provider=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)
model=data.get("model") or {}
sys.stdout.write(str(model.get("provider") or data.get("provider") or ""))' || true)
    model=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)
model=data.get("model") or {}
sys.stdout.write(str(model.get("id") or model.get("display_name") or ""))' || true)
  fi
  if ! is_gateway "$provider" "$model" ""; then
    return 0
  fi
  print_from_cache
  if [ "$kick" -eq 1 ]; then
    kick_refresh_if_due
  fi
}

cmd_install_claude() {
  local settings_dir settings
  need_python
  settings_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  settings="$settings_dir/settings.json"
  mkdir -p "$settings_dir"
  python3 - "$settings" "$SCRIPT_DIR/fm-llm-budget.sh" <<'PY'
import json, os, sys
path, command = sys.argv[1], sys.argv[2]
data = {}
if os.path.isfile(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"error: Claude settings are not valid JSON: {error}")
    if not isinstance(data, dict):
        raise SystemExit("error: Claude settings root must be an object")
data["statusLine"] = {
    "type": "command",
    "command": f"{command} claude-statusline --kick-refresh",
}
tmp = path + f".tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(path)
PY
}

cmd_refresh() {
  need_python
  mkdir_state
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  else
    return 0
  fi
  python3 - "$CACHE" "$EMAIL_FILE" "$CAP_FILE" "$OAUTH_FILE" \
    "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "$DEFAULT_CAP" \
    "$GATEWAY_HEALTH_PATH" <<'PY'
import json, os, re, subprocess, sys, time, urllib.error, urllib.request
from datetime import datetime, timezone
from pathlib import Path

cache_path, email_file, cap_file, oauth_file, keychain_service, keychain_account, default_cap, health_path = sys.argv[1:9]
default_cap = float(default_cap)

def log(message):
    sys.stderr.write(f"fm-llm-budget: {message}\n")

def atomic_write(path, payload, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    data = json.dumps(payload, separators=(",", ":"), ensure_ascii=True) + "\n"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(data)
    os.replace(tmp, path)

def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

def rfc3339_millis(dt):
    utc = dt.astimezone(timezone.utc)
    millis = int(utc.microsecond / 1000)
    return utc.strftime("%Y-%m-%dT%H:%M:%S.") + f"{millis:03d}Z"

def month_window():
    now = datetime.now().astimezone()
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return start, now

def resolve_email():
    for candidate in (
        os.environ.get("RIPPLING_EMAIL", "").strip(),
        Path(email_file).read_text(encoding="utf-8").strip() if Path(email_file).is_file() else "",
    ):
        if candidate.lower().endswith("@rippling.com") and "@" in candidate:
            return candidate.lower()
    user = os.environ.get("USER") or ""
    if user:
        try:
            output = subprocess.check_output(
                ["/usr/bin/dscl", ".", "-read", f"/Users/{user}",
                 "EMailAddress", "dsAttrTypeStandard:EMailAddress"],
                text=True, stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            output = ""
        for token in output.replace(":", " ").split():
            if token.lower().endswith("@rippling.com"):
                return token.lower()
    try:
        output = subprocess.check_output(
            ["git", "config", "--global", "user.email"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        output = ""
    if output.lower().endswith("@rippling.com"):
        return output.lower()
    return ""

def resolve_cap(fallback):
    env = os.environ.get("FM_LLM_BUDGET_CAP", "").strip()
    if env:
        try:
            value = float(env)
            if value > 0:
                return value
        except ValueError:
            pass
    if Path(cap_file).is_file():
        try:
            value = float(Path(cap_file).read_text(encoding="utf-8").split()[0])
            if value > 0:
                return value
        except (OSError, ValueError, IndexError):
            pass
    return fallback

def save_budget(*, source, email, cap, spend, month_start):
    remaining = cap - spend
    exhausted = remaining <= 0
    if remaining < 0:
        remaining = 0.0
    payload = {
        "version": 1,
        "source": source,
        "email": email,
        "cap": cap,
        "spend": spend,
        "remaining": remaining,
        "exhausted": exhausted,
        "fetched_at_unix": int(time.time()),
        "month_start_unix": int(month_start.timestamp()),
    }
    atomic_write(cache_path, payload)
    return payload

def http_json(url, *, method="GET", headers=None, body=None, timeout=30):
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, raw, dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read() or b"", dict(error.headers or {})

def api_keys():
    api = os.environ.get("DD_API_KEY") or os.environ.get("DATADOG_API_KEY") or ""
    app = os.environ.get("DD_APP_KEY") or os.environ.get("DATADOG_APP_KEY") or ""
    return api.strip(), app.strip()

def keychain_session():
    if sys.platform == "darwin":
        try:
            raw = subprocess.check_output(
                ["security", "find-generic-password", "-s", keychain_service,
                 "-a", keychain_account, "-w"],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
            return json.loads(raw)
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
            return None
    return load_json(oauth_file)

def datadog_headers():
    api, app = api_keys()
    if api and app:
        return {"DD-API-KEY": api, "DD-APPLICATION-KEY": app, "Content-Type": "application/json"}
    session = keychain_session()
    if not session:
        return None
    tokens = session.get("tokens") or session
    access = tokens.get("access_token") or ""
    if not access:
        return None
    return {"Authorization": f"Bearer {access}", "Content-Type": "application/json"}

def sum_datadog(raw):
    data = json.loads(raw)
    buckets = (((data.get("data") or {}).get("buckets")) or [])
    total = 0.0
    for bucket in buckets:
        points = ((bucket.get("computes") or {}).get("c0")) or []
        if points is None:
            continue
        for point in points:
            value = (point or {}).get("value")
            if value is None:
                continue
            total += float(value)
    return total

def fetch_datadog(email, start, now):
    headers = datadog_headers()
    if headers is None:
        return None, "no-datadog-auth"
    body = json.dumps({
        "compute": [{
            "aggregation": "sum",
            "interval": "15m",
            "metric": "@cost",
            "type": "timeseries",
        }],
        "filter": {
            "from": rfc3339_millis(start),
            "to": rfc3339_millis(now),
            "indexes": ["*"],
            "query": (
                'service:llm-gateway env:devexp @key_type:personal '
                f'"audit trail message" @user_email:"{email}"'
            ),
            "storage_tier": "flex",
        },
    }).encode()
    status, raw, _headers = http_json(
        "https://api.datadoghq.com/api/v2/logs/analytics/aggregate",
        method="POST", headers=headers, body=body,
    )
    if status == 401 and "Authorization" in headers:
        return None, "datadog-unauthorized"
    if status < 200 or status >= 300:
        return None, f"datadog-http-{status}"
    return sum_datadog(raw), None

def wavecode_home():
    override = (os.environ.get("WAVECODE_CONFIG_PATH") or os.environ.get("WAVECODE_HOME") or "").strip()
    if override:
        return Path(override)
    return Path.home() / ".wavecode"

def wavecode_key():
    err = ""
    try:
        proc = subprocess.run(
            ["wavecode", "llm-gateway", "get-api-key"],
            capture_output=True, text=True, check=False,
        )
        err = proc.stderr or ""
        key = (proc.stdout or "").strip()
        if key:
            key = key.splitlines()[-1].strip()
        if proc.returncode == 0 and key:
            return key, err, None
    except OSError:
        err = "no-wavecode"
    cfg = load_json(wavecode_home() / "config" / "llm_gateway.json")
    if isinstance(cfg, dict):
        key = str(cfg.get("llm_key") or "").strip()
        url = str(cfg.get("llm_gateway_url") or "").strip().rstrip("/")
        if key:
            return key, err, url or None
    return "", err, None

def gateway_exhausted_from_text(text):
    return "budget is exhausted" in (text or "").lower() or "budget exhausted" in (text or "").lower()

def gateway_fallback():
    key, err, configured_url = wavecode_key()
    base = configured_url or "https://llm-gateway.us1.ripplingdev.net/api/v2"
    if key:
        status, raw, _headers = http_json(
            base + health_path,
            headers={"Authorization": f"Bearer {key}", "Accept": "text/plain, application/json"},
        )
        text = raw.decode("utf-8", "replace")
        if status == 402:
            match = re.search(
                r"consumed\s+([0-9.]+)\s*,\s*total\s+([0-9.]+)",
                text, re.IGNORECASE,
            )
            if not match:
                cap = resolve_cap(default_cap)
                return {"cap": cap, "spend": cap}, None
            spend = float(match.group(1))
            cap = float(match.group(2))
            return {"cap": cap, "spend": spend}, None
        if status == 200:
            return None, "gateway-healthy-no-dollars"
        if gateway_exhausted_from_text(text) or gateway_exhausted_from_text(err):
            cap = resolve_cap(default_cap)
            return {"cap": cap, "spend": cap}, None
        return None, f"gateway-http-{status}"
    if gateway_exhausted_from_text(err):
        cap = resolve_cap(default_cap)
        return {"cap": cap, "spend": cap}, None
    if err == "no-wavecode":
        return None, "no-wavecode"
    return None, "no-wavecode-key"

email = resolve_email()
start, now = month_window()
cap = resolve_cap(default_cap)
if not email:
    spend, error = None, "no-email"
else:
    spend, error = fetch_datadog(email, start, now)
if error is None:
    save_budget(source="datadog", email=email, cap=cap, spend=float(spend), month_start=start)
    raise SystemExit(0)

fallback, fallback_error = gateway_fallback()
if fallback is not None:
    save_budget(
        source="gateway-402",
        email=email,
        cap=float(fallback["cap"]),
        spend=float(fallback["spend"]),
        month_start=start,
    )
    if error != "no-datadog-auth":
        log(error)
    raise SystemExit(0)

log(error)
if fallback_error:
    log(fallback_error)
raise SystemExit(1)
PY
}

cmd_login() {
  need_python
  mkdir_state
  python3 - "$OAUTH_FILE" "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" <<'PY'
import hashlib, json, os, secrets, socket, subprocess, sys, time, urllib.parse, urllib.request, webbrowser
from pathlib import Path

oauth_file, keychain_service, keychain_account = sys.argv[1:4]
CLIENT_NAME = "firstmate-llm-budget"
REGISTER = "https://api.datadoghq.com/api/v2/oauth2/register"
AUTHORIZE = "https://app.datadoghq.com/oauth2/v1/authorize"
TOKEN = "https://api.datadoghq.com/oauth2/v1/token"
SCOPES = "logs_read_data logs_read_index_data"
PORTS = (18765, 18766, 18767, 18768)

def b64url(raw: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def http_json(url, *, method="POST", headers=None, body=None):
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status, json.loads(response.read().decode())

listener = None
port = None
for candidate in PORTS:
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", candidate))
        sock.listen(1)
        listener = sock
        port = candidate
        break
    except OSError:
        sock.close()
if listener is None:
    raise SystemExit("error: Datadog OAuth callback ports 18765-18768 are busy")

redirect = f"http://127.0.0.1:{port}/oauth/callback"
status, registration = http_json(
    REGISTER,
    headers={"Content-Type": "application/json"},
    body=json.dumps({
        "client_name": CLIENT_NAME,
        "redirect_uris": [redirect],
        "grant_types": ["authorization_code", "refresh_token"],
    }).encode(),
)
if status not in (200, 201):
    raise SystemExit(f"error: Datadog OAuth client registration failed (HTTP {status})")
client_id = registration["client_id"]
verifier = b64url(secrets.token_bytes(32))
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = b64url(secrets.token_bytes(16))
query = urllib.parse.urlencode({
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": redirect,
    "scope": SCOPES,
    "state": state,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
})
try:
    webbrowser.open(f"{AUTHORIZE}?{query}")
except Exception:
    subprocess.run(["/usr/bin/open", f"{AUTHORIZE}?{query}"], check=False)

listener.settimeout(300)
try:
    conn, _addr = listener.accept()
except (TimeoutError, socket.timeout):
    listener.close()
    raise SystemExit("error: Datadog authorization timed out")
conn.settimeout(5)
request = b""
try:
    while b"\r\n" not in request and len(request) < 8192:
        chunk = conn.recv(1024)
        if not chunk:
            break
        request += chunk
except OSError:
    request = b""
first = request.split(b"\r\n", 1)[0].decode("latin1", "replace")
parts = first.split(" ")
path = parts[1] if len(parts) >= 2 else ""
params = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
code = (params.get("code") or [""])[0]
got_state = (params.get("state") or [""])[0]
error = (params.get("error") or [""])[0]
ok = bool(code) and not error and got_state == state
body = (
    b"<!doctype html><title>Firstmate LLM budget</title><p>Datadog connected. You can close this tab.</p>"
    if ok else
    b"<!doctype html><title>Firstmate LLM budget</title><p>Datadog connection failed.</p>"
)
try:
    conn.sendall(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\nConnection: close\r\n\r\n"
        + body
    )
except OSError:
    pass
conn.close()
listener.close()
if error:
    raise SystemExit(f"error: Datadog authorization failed: {error}")
if not ok:
    raise SystemExit("error: Datadog OAuth callback was invalid")

token_body = urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "client_id": client_id,
    "code": code,
    "redirect_uri": redirect,
    "code_verifier": verifier,
}).encode()
_status, tokens = http_json(
    TOKEN,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    body=token_body,
)
session = {
    "client": {"client_id": client_id, "client_name": CLIENT_NAME, "redirect_uris": [redirect]},
    "tokens": {
        "access_token": tokens["access_token"],
        "refresh_token": tokens.get("refresh_token"),
        "expires_in": tokens.get("expires_in"),
        "issued_at": int(__import__("time").time()),
    },
}
blob = json.dumps(session)
if sys.platform == "darwin":
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", keychain_service,
         "-a", keychain_account, "-w", blob],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
else:
    Path(oauth_file).parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(oauth_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(blob + "\n")
print("datadog-oauth-saved")
PY
}

[ "$#" -gt 0 ] || { usage; exit 2; }
case "$1" in
  print) shift; cmd_print "$@" ;;
  refresh) cmd_refresh ;;
  login) cmd_login ;;
  claude-statusline) shift; cmd_claude_statusline "$@" ;;
  install-claude) cmd_install_claude ;;
  -h|--help) usage ;;
  *) die "unknown command: $1" ;;
esac
