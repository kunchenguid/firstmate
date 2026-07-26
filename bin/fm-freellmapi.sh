#!/usr/bin/env bash
# fm-freellmapi.sh - manage the fleet's pinned, localhost-only FreeLLMAPI lane.
#
# FreeLLMAPI (https://github.com/tashfeenahmed/freellmapi, MIT) is a third-party
# local proxy that pools free-tier LLM provider keys behind one OpenAI-compatible
# endpoint. This script is the single owner of the fleet's vetted install: it
# pins one audited upstream commit, generates the mandatory ENCRYPTION_KEY
# without ever printing it, starts the service bound to 127.0.0.1 only, verifies
# that binding before declaring success, seeds provider keys from the fleet's
# gitignored .env without exposing their values, and stops the service cleanly.
# Non-sensitive bulk/scout use only - docs/freellmapi-lane.md owns the usage
# policy, known-risk statement, and removal procedure.
#
# Usage:
#   fm-freellmapi.sh install --accept-risks     install or repair the pinned build
#   fm-freellmapi.sh start [--port <p>] [--catalog-sync]
#   fm-freellmapi.sh status [--port <p>]
#   fm-freellmapi.sh seed-keys <platform>=<ENV_VAR> [<platform>=<ENV_VAR> ...]
#   fm-freellmapi.sh stop
#   fm-freellmapi.sh --help
#
# The install lives under $FM_HOME/data/freellmapi (gitignored, chmod 0700):
#   app/                 upstream checkout at the exact pinned commit, built
#   db/freeapi.db        service state, kept outside app/ so reinstall preserves it
#   encryption.key       generated 64-hex AES-256-GCM key, mode 0600
#   dashboard.credentials generated local dashboard login, mode 0600
#   run/server.pid run/server.log  runtime records
#
# Secret-safety contract (the reason this wrapper exists):
#   - Secret values (provider keys, ENCRYPTION_KEY, dashboard password, session
#     token) never appear in stdout, stderr, argv, this script's error messages,
#     or files other than the mode-0600 secret files listed above. Secrets travel
#     to child processes via environment or stdin only, never command arguments
#     (never on argv; not printed). At runtime they live only in process env,
#     mode-0600 files, and stdin pipes; the same OS user can still inspect those
#     (for example /proc/<pid>/environ on Linux). Do not run this script under
#     shell xtrace (bash -x or set -o xtrace): it dumps env assignments and pipes.
#   - This script never prints the server log; on failure it prints the log path.
#   - start verifies every TCP listener of the server process is bound to
#     127.0.0.1 and stops the server if verification fails; status fails with a
#     warning on the same condition but does not stop (use stop for that).
#   - install refuses to run without --accept-risks and restates the known
#     dependency-vulnerability findings every time.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Exact pin - change only after re-verifying upstream authenticity, CI, and key
# handling and updating the safety-contract regression coverage.
FM_FREELLMAPI_REPO_URL=https://github.com/tashfeenahmed/freellmapi.git
FM_FREELLMAPI_PIN=526c86349891bd336b470481ee2d732cd8e13c14
FM_FREELLMAPI_PIN_DATE=2026-07-20

FM_FREELLMAPI_DEFAULT_PORT=3001
FM_FREELLMAPI_START_TIMEOUT=${FM_FREELLMAPI_START_TIMEOUT:-30}
FM_FREELLMAPI_STOP_TIMEOUT=${FM_FREELLMAPI_STOP_TIMEOUT:-10}

LANE_HOME="$FM_HOME/data/freellmapi"
APP_DIR="$LANE_HOME/app"
DB_PATH="$LANE_HOME/db/freeapi.db"
KEY_FILE="$LANE_HOME/encryption.key"
CRED_FILE="$LANE_HOME/dashboard.credentials"
RUN_DIR="$LANE_HOME/run"
PID_FILE="$RUN_DIR/server.pid"
IDENTITY_FILE="$RUN_DIR/server.identity"
LOG_FILE="$RUN_DIR/server.log"
ENV_FILE="$FM_HOME/.env"

die() {
  printf 'fm-freellmapi.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  # Print the header comment through the last contract bullet (before set -eu).
  sed -n '2,43{s/^# \{0,1\}//;p;}' "$SCRIPT_DIR/fm-freellmapi.sh"
}

print_risks() {
  cat <<EOF
KNOWN RISKS - FreeLLMAPI lane (pin $FM_FREELLMAPI_PIN, $FM_FREELLMAPI_PIN_DATE):
  - npm ci at this pin reported 21 dependency vulnerabilities
    (3 critical, 7 high, 9 moderate, 2 low; npm audit 2026-07-24).
  - npm ci executes dependency install scripts (native modules build at install).
  - Every prompt sent through the lane goes to third-party free providers;
    some keyless providers may use prompts for training.
  - This service is for ISOLATED LOCAL USE ONLY: localhost binding, no tunnel,
    no port forwarding, no sensitive content, never a primary-model substitute.
  Full policy: docs/freellmapi-lane.md.
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found on PATH"
}

pid_alive() {
  kill -0 "$1" 2>/dev/null
}

process_start_identity() {
  ps -p "$1" -o lstart= 2>/dev/null
}

pid_is_our_server() {
  local pid=$1 cmd cwd recorded current
  [ -f "$IDENTITY_FILE" ] || return 1
  recorded=$(cat "$IDENTITY_FILE" 2>/dev/null || true)
  [ -n "$recorded" ] || return 1
  current=$(process_start_identity "$pid") || return 1
  [ "$current" = "$recorded" ] || return 1
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case " $cmd " in
    *" $APP_DIR/server/dist/index.js "*) ;;
    *) return 1 ;;
  esac
  cwd=$(lsof -nP -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || return 1
  [ "$cwd" = "$APP_DIR/server" ]
}

running_pid() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  pid_alive "$pid" && pid_is_our_server "$pid" || return 1
  printf '%s\n' "$pid"
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) die "invalid port '$1'" ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "invalid port '$1'"
}

# Fail closed unless every TCP listener owned by the server pid is bound to
# 127.0.0.1. Verification is mandatory: if lsof is missing or fails, the caller
# must treat the service as unverified and stop it.
verify_loopback_only() {
  local pid=$1 listeners bad
  command -v lsof >/dev/null 2>&1 || return 1
  listeners=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $(NF-1)}') || return 1
  [ -n "$listeners" ] || return 1
  bad=$(printf '%s\n' "$listeners" | grep -v '^127\.0\.0\.1:' || true)
  [ -z "$bad" ]
}

ping_ok() {
  local port=$1
  curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$port/api/ping" 2>/dev/null
}

ensure_lane_home() {
  mkdir -p "$LANE_HOME"
  chmod 700 "$LANE_HOME"
}

ensure_encryption_key() {
  local key
  if [ ! -f "$KEY_FILE" ]; then
    require_tool openssl
    ensure_lane_home
    ( umask 077 && openssl rand -hex 32 > "$KEY_FILE.tmp" && mv "$KEY_FILE.tmp" "$KEY_FILE" )
    printf 'fm-freellmapi.sh: generated new ENCRYPTION_KEY at %s (value not shown)\n' "$KEY_FILE" >&2
  fi
  key=$(cat "$KEY_FILE")
  case "$key" in
    *[!0-9a-f]*|'') die "encryption key at $KEY_FILE is not 64 lowercase hex chars; refusing to start (regenerate by removing the file - existing stored provider keys become unreadable)" ;;
  esac
  [ "${#key}" -eq 64 ] || die "encryption key at $KEY_FILE is not 64 lowercase hex chars; refusing to start (regenerate by removing the file - existing stored provider keys become unreadable)"
}

# Read one variable's value from the fleet's gitignored .env without sourcing it
# (sourcing would execute arbitrary content). Prints the value to stdout for the
# caller to capture; the value must never be echoed anywhere else.
env_file_value() {
  local name=$1 value
  value=$(awk -v name="$name" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      eq = index(line, "=")
      if (eq > 1 && substr(line, 1, eq - 1) == name) { val = substr(line, eq + 1) }
    }
    END { printf "%s", val }
  ' "$ENV_FILE")
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

cmd_install() {
  local accept=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --accept-risks) accept=1; shift ;;
      *) die "unknown install option '$1'" ;;
    esac
  done
  print_risks >&2
  if [ "$accept" -ne 1 ]; then
    die "refusing to install without --accept-risks (read the risk statement above and docs/freellmapi-lane.md first)"
  fi
  require_tool git
  require_tool npm
  require_tool node

  ensure_lane_home
  mkdir -p "$(dirname "$DB_PATH")" "$RUN_DIR"

  if [ ! -d "$APP_DIR/.git" ]; then
    mkdir -p "$APP_DIR"
    git -C "$APP_DIR" init -q
    git -C "$APP_DIR" remote add origin "$FM_FREELLMAPI_REPO_URL"
  fi
  printf 'fm-freellmapi.sh: fetching pinned commit %s\n' "$FM_FREELLMAPI_PIN" >&2
  git -C "$APP_DIR" fetch -q --depth 1 origin "$FM_FREELLMAPI_PIN" \
    || die "could not fetch pinned commit $FM_FREELLMAPI_PIN from $FM_FREELLMAPI_REPO_URL"
  git -C "$APP_DIR" checkout -q --detach "$FM_FREELLMAPI_PIN" \
    || die "could not check out pinned commit $FM_FREELLMAPI_PIN"

  local head_sha
  head_sha=$(git -C "$APP_DIR" rev-parse HEAD)
  [ "$head_sha" = "$FM_FREELLMAPI_PIN" ] \
    || die "checkout mismatch: HEAD is $head_sha, expected pinned $FM_FREELLMAPI_PIN; refusing to build unverified content"

  printf 'fm-freellmapi.sh: installing lockfile-pinned dependencies (npm ci)\n' >&2
  ( cd "$APP_DIR" && npm ci ) || die "npm ci failed in $APP_DIR"
  printf 'fm-freellmapi.sh: building server and dashboard\n' >&2
  ( cd "$APP_DIR" && npm run build ) || die "npm run build failed in $APP_DIR"

  printf 'fm-freellmapi.sh: installed FreeLLMAPI at pinned commit %s under %s\n' \
    "$FM_FREELLMAPI_PIN" "$APP_DIR"
  printf 'fm-freellmapi.sh: next: fm-freellmapi.sh start\n'
}

cmd_start() {
  local port=${FM_FREELLMAPI_PORT:-$FM_FREELLMAPI_DEFAULT_PORT} catalog_sync=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) [ "$#" -ge 2 ] || die "--port requires a value"; port=$2; shift 2 ;;
      --port=*) port=${1#*=}; shift ;;
      --catalog-sync) catalog_sync=1; shift ;;
      *) die "unknown start option '$1'" ;;
    esac
  done
  validate_port "$port"
  require_tool node
  require_tool curl
  command -v lsof >/dev/null 2>&1 \
    || die "lsof is required to verify the localhost-only binding; refusing to start unverifiable"

  [ -f "$APP_DIR/server/dist/index.js" ] \
    || die "no built install at $APP_DIR; run: fm-freellmapi.sh install --accept-risks"

  local recorded_pid
  if [ -f "$PID_FILE" ]; then
    recorded_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$recorded_pid" in
      ''|*[!0-9]*) ;;
      *)
        if pid_alive "$recorded_pid"; then
          pid_is_our_server "$recorded_pid" \
            || die "pid $recorded_pid is live but its lane identity cannot authenticate it; refusing to overwrite the pid record"
          die "already running (pid $recorded_pid); use status or stop"
        fi
        ;;
    esac
  fi

  ensure_encryption_key
  mkdir -p "$RUN_DIR" "$(dirname "$DB_PATH")"

  # CATALOG_SYNC_DISABLED=1 is the default: the pinned snapshot catalog works
  # offline and the lane keeps zero background egress unless opted in.
  local sync_disabled=1
  [ "$catalog_sync" -eq 1 ] && sync_disabled=0

  # The key is passed via environment, never argv (so argv / ps args stay clean).
  # It still lives in the node process env for the whole run; same-user tools
  # can inspect that. NODE_ENV=production makes upstream refuse to fall back to
  # any implicit dev key. The background command is a simple command so $! is
  # the node pid itself, not a wrapping subshell.
  (
    cd "$APP_DIR/server" || exit 1
    NODE_ENV=production \
    HOST=127.0.0.1 \
    PORT="$port" \
    ENCRYPTION_KEY="$(cat "$KEY_FILE")" \
    FREEAPI_DB_PATH="$DB_PATH" \
    CATALOG_SYNC_DISABLED="$sync_disabled" \
    nohup node "$APP_DIR/server/dist/index.js" >> "$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
  ) || die "could not launch the server from $APP_DIR/server"

  local pid waited=0
  pid=$(cat "$PID_FILE")
  if ! process_start_identity "$pid" > "$IDENTITY_FILE.tmp" || [ ! -s "$IDENTITY_FILE.tmp" ]; then
    stop_pid "$pid"
    rm -f "$PID_FILE" "$IDENTITY_FILE.tmp"
    die "could not record the server process start identity; server stopped"
  fi
  mv "$IDENTITY_FILE.tmp" "$IDENTITY_FILE"
  chmod 600 "$PID_FILE" "$IDENTITY_FILE" "$LOG_FILE" 2>/dev/null || true
  until ping_ok "$port"; do
    if ! pid_alive "$pid"; then
      rm -f "$PID_FILE" "$IDENTITY_FILE"
      die "server exited during startup; see log at $LOG_FILE (not printed here by policy)"
    fi
    if [ "$waited" -ge "$FM_FREELLMAPI_START_TIMEOUT" ]; then
      stop_pid "$pid"
      rm -f "$PID_FILE" "$IDENTITY_FILE"
      die "server did not answer /api/ping on 127.0.0.1:$port within ${FM_FREELLMAPI_START_TIMEOUT}s; stopped it; see log at $LOG_FILE"
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if ! verify_loopback_only "$pid"; then
    stop_pid "$pid"
    rm -f "$PID_FILE" "$IDENTITY_FILE"
    die "REFUSED: could not prove every listener is bound to 127.0.0.1; server stopped (a non-loopback or unverifiable binding is never tolerated)"
  fi

  printf 'fm-freellmapi.sh: running on http://127.0.0.1:%s (loopback binding verified, pid %s)\n' "$port" "$pid"
  printf 'fm-freellmapi.sh: non-sensitive bulk/scout use only - see docs/freellmapi-lane.md\n'
}

cmd_status() {
  local port=${FM_FREELLMAPI_PORT:-$FM_FREELLMAPI_DEFAULT_PORT} pid
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) [ "$#" -ge 2 ] || die "--port requires a value"; port=$2; shift 2 ;;
      --port=*) port=${1#*=}; shift ;;
      *) die "unknown status option '$1'" ;;
    esac
  done
  validate_port "$port"
  if ! pid=$(running_pid); then
    printf 'fm-freellmapi.sh: not running\n'
    return 1
  fi
  if ! ping_ok "$port"; then
    printf 'fm-freellmapi.sh: pid %s is alive but /api/ping on 127.0.0.1:%s failed\n' "$pid" "$port"
    return 1
  fi
  if ! verify_loopback_only "$pid"; then
    # status alerts only; start is the path that stops a bad bind. Operators
    # must run stop (or restart via start) after this warning.
    printf 'fm-freellmapi.sh: WARNING: pid %s has a non-loopback or unverifiable listener; run stop (status does not stop)\n' "$pid" >&2
    return 1
  fi
  printf 'fm-freellmapi.sh: running on http://127.0.0.1:%s (loopback binding verified, pid %s)\n' "$port" "$pid"
}

# Obtain a dashboard session token into DASHBOARD_TOKEN using generated
# credentials stored only in the mode-0600 credentials file.
# First run claims the fresh install over loopback; later runs log in.
dashboard_token() {
  local port=$1 email password status_json needs token_json token
  if [ ! -f "$CRED_FILE" ]; then
    require_tool openssl
    ensure_lane_home
    ( umask 077 && {
        printf 'email=firstmate-lane@localhost.local\n'
        printf 'password=%s\n' "$(openssl rand -hex 24)"
      } > "$CRED_FILE.tmp" && mv "$CRED_FILE.tmp" "$CRED_FILE" )
    printf 'fm-freellmapi.sh: generated dashboard credentials at %s (value not shown)\n' "$CRED_FILE" >&2
  fi
  email=$(awk -F= '$1 == "email" {print $2}' "$CRED_FILE")
  password=$(awk -F= '$1 == "password" {print $2}' "$CRED_FILE")
  [ -n "$email" ] && [ -n "$password" ] \
    || die "credentials file $CRED_FILE is malformed; remove it to regenerate"

  status_json=$(curl -fsS --max-time 5 "http://127.0.0.1:$port/api/auth/status") \
    || die "could not read dashboard auth status on 127.0.0.1:$port"
  case "$status_json" in
    *'"needsSetup":true'*) needs=1 ;;
    *) needs=0 ;;
  esac

  # Credentials travel via stdin, never argv.
  if [ "$needs" -eq 1 ]; then
    token_json=$(printf '{"email":"%s","password":"%s"}' "$email" "$password" \
      | curl -fsS --max-time 5 -H 'Content-Type: application/json' -d @- \
          "http://127.0.0.1:$port/api/auth/setup") \
      || die "dashboard first-run setup failed on 127.0.0.1:$port"
  else
    token_json=$(printf '{"email":"%s","password":"%s"}' "$email" "$password" \
      | curl -fsS --max-time 5 -H 'Content-Type: application/json' -d @- \
          "http://127.0.0.1:$port/api/auth/login") \
      || die "dashboard login failed on 127.0.0.1:$port (if the dashboard was claimed manually, remove $CRED_FILE and reset the install)"
  fi
  token=$(printf '%s' "$token_json" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || die "dashboard did not return a session token"
  DASHBOARD_TOKEN=$token
}

cmd_seed_keys() {
  [ "$#" -ge 1 ] || die "usage: fm-freellmapi.sh seed-keys <platform>=<ENV_VAR> [...]"
  local port=${FM_FREELLMAPI_PORT:-$FM_FREELLMAPI_DEFAULT_PORT} pid
  require_tool curl
  [ -f "$ENV_FILE" ] || die "fleet .env not found at $ENV_FILE; nothing to seed from"
  pid=$(running_pid) || die "no live recorded lane process; start it before seeding keys"
  verify_loopback_only "$pid" \
    || die "recorded lane process has a non-loopback or unverifiable listener; refusing to send secrets"
  ping_ok "$port" || die "service is not answering on 127.0.0.1:$port; start it first"

  # Validate the whole request before the first write so a typo cannot leave a
  # half-seeded key set.
  local mapping platform var value
  for mapping in "$@"; do
    case "$mapping" in
      *=*) ;;
      *) die "invalid mapping '$mapping'; expected <platform>=<ENV_VAR>" ;;
    esac
    platform=${mapping%%=*}
    var=${mapping#*=}
    case "$platform" in
      ''|*[!a-z0-9_-]*) die "invalid platform name '$platform'" ;;
    esac
    case "$var" in
      ''|*[!A-Z0-9_]*) die "invalid env var name '$var'; expected an UPPER_SNAKE name from $ENV_FILE" ;;
    esac
    value=$(env_file_value "$var") || die "$var is missing or empty in $ENV_FILE"
    case "$value" in
      *[\"\\]*|*[![:print:]]*) die "$var contains characters this tool refuses to forward (quote, backslash, or non-printable); seed it via the dashboard instead" ;;
    esac
  done

  local hdr
  SEED_TMPDIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/fm-freellmapi.XXXXXX")
  trap 'rm -rf "$SEED_TMPDIR"' EXIT
  DASHBOARD_TOKEN=
  dashboard_token "$port"
  hdr="$SEED_TMPDIR/auth-header"
  # The token reaches curl through a header file, never argv.
  ( umask 077 && printf 'Authorization: Bearer %s\n' "$DASHBOARD_TOKEN" > "$hdr" )

  local http_code
  for mapping in "$@"; do
    platform=${mapping%%=*}
    var=${mapping#*=}
    value=$(env_file_value "$var") || die "$var is missing or empty in $ENV_FILE"
    # The key value travels via stdin, never argv; the response body (which
    # echoes a masked copy) is discarded.
    http_code=$(printf '{"platform":"%s","key":"%s","label":"%s"}' "$platform" "$value" "$var" \
      | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
          -H 'Content-Type: application/json' -H "@$hdr" -d @- \
          "http://127.0.0.1:$port/api/keys") \
      || die "could not reach /api/keys on 127.0.0.1:$port"
    case "$http_code" in
      200|201) printf 'fm-freellmapi.sh: seeded %s key from %s (value not shown)\n' "$platform" "$var" ;;
      *) die "seeding $platform key from $var failed (HTTP $http_code); the key value was not printed anywhere" ;;
    esac
  done
}

stop_pid() {
  local pid=$1 waited=0
  kill -TERM "$pid" 2>/dev/null || true
  while pid_alive "$pid"; do
    if [ "$waited" -ge "$FM_FREELLMAPI_STOP_TIMEOUT" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

cmd_stop() {
  [ "$#" -eq 0 ] || die "stop takes no options"
  local pid
  [ -f "$PID_FILE" ] || die "not running (no pid record at $PID_FILE)"
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) rm -f "$PID_FILE" "$IDENTITY_FILE"; die "pid record at $PID_FILE was malformed; removed it" ;; esac
  if ! pid_alive "$pid"; then
    rm -f "$PID_FILE" "$IDENTITY_FILE"
    printf 'fm-freellmapi.sh: was not running (stale pid record removed)\n'
    return 0
  fi
  pid_is_our_server "$pid" \
    || die "pid $pid is not this lane's server process; refusing to signal it (remove $PID_FILE by hand after checking)"
  stop_pid "$pid"
  rm -f "$PID_FILE" "$IDENTITY_FILE"
  printf 'fm-freellmapi.sh: stopped (pid %s)\n' "$pid"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  install) cmd_install "$@" ;;
  start) cmd_start "$@" ;;
  status) cmd_status "$@" ;;
  seed-keys) cmd_seed_keys "$@" ;;
  stop) cmd_stop "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; die "unknown command '$COMMAND'" ;;
esac
