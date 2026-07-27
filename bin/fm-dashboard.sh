#!/usr/bin/env bash
# fm-dashboard.sh - lifecycle owner for the live fleet dashboard sidecar.
#
# A long-running, read-only HTTP board over firstmate state. Independent of the
# firstmate session lock and of firstmate start/stop. This script owns start,
# stop, status, and foreground run. The HTTP server is a Rust binary built from
# dashboard/ (cargo project; tiny_http + serde_json, no async framework).
# When the release binary is absent, this script runs `cargo build --release`.
#
# On hosts without systemd (e.g. Gentoo OpenRC), `start` daemonizes a portable
# supervisor loop that restarts the server within 10s if it dies. An optional
# systemd unit example for other hosts is documented in docs/dashboard.md and is
# not the default path here.
#
# Usage:
#   fm-dashboard.sh start     Validate home, ensure token, daemonize supervisor
#   fm-dashboard.sh stop      Stop supervisor and server
#   fm-dashboard.sh status    Print running / stopped and bind details
#   fm-dashboard.sh run       Foreground server (no restart loop; for debug)
#
# Environment:
#   FM_HOME           Operational home (required shape: state/ + data/ +
#                     firstmate markers). Defaults to the tracked repo root
#                     when unset only if that root is firstmate-shaped.
#   FM_ROOT_OVERRIDE  Override the tracked code root that supplies bin/ and the
#                     static UI (default: parent of this script's directory).
#   FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE / FM_DATA_OVERRIDE
#                     Test seams for state, config, and data directories.
#
# Local config (gitignored under FM_HOME):
#   config/dashboard-bind    Bind as IP or IP:PORT (default: tailscale ip -4
#                            and port 8391). Never 0.0.0.0 / ::.
#   config/dashboard-token   Bearer token, mode 0600, auto-created on first start.
#
# Runtime files under state/dashboard/ (only writable location for this tool):
#   supervisor.pid  server.pid  stop  server.log  supervisor.log
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DEFAULT_PORT=8391
DASH_CRATE_DIR="$FM_ROOT/dashboard"
SERVER_BIN="$DASH_CRATE_DIR/target/release/fm-dashboard-server"
STATIC_DIR="$SCRIPT_DIR/fm-dashboard-static"

usage() {
  cat <<'EOF'
usage: fm-dashboard.sh start|stop|status|run

Lifecycle for the live fleet dashboard HTTP server.
See docs/dashboard.md for bind, auth, and supervisor design.
EOF
}

die() {
  printf 'fm-dashboard: %s\n' "$*" >&2
  exit 1
}

resolve_home() {
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  printf '%s\n' "$FM_ROOT"
}

# Firstmate-shaped: state/ and data/ directories plus at least one durable
# firstmate marker. Refuses bare empty directories and unrelated trees.
is_firstmate_home() {
  local home=$1
  [ -n "$home" ] || return 1
  [ -d "$home" ] || return 1
  [ -d "$home/state" ] || return 1
  [ -d "$home/data" ] || return 1
  if [ -f "$home/data/backlog.md" ] ||
    [ -f "$home/data/projects.md" ] ||
    [ -f "$home/AGENTS.md" ] ||
    [ -f "$home/.fm-secondmate-home" ]; then
    return 0
  fi
  return 1
}

require_home() {
  local home
  home=$(resolve_home)
  if [ -z "${FM_HOME:-}" ] && ! is_firstmate_home "$home"; then
    die "FM_HOME is unset and the code root is not firstmate-shaped: $home"
  fi
  if [ -z "${FM_HOME:-}" ]; then
    # Explicit export so children and status always see a concrete home.
    export FM_HOME=$home
  fi
  home=$(resolve_home)
  if ! is_firstmate_home "$home"; then
    die "FM_HOME is missing or not firstmate-shaped (need state/, data/, and a firstmate marker such as data/backlog.md): $home"
  fi
  FM_HOME=$home
  export FM_HOME
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  DASH_DIR="$STATE/dashboard"
  SUPERVISOR_PID_FILE="$DASH_DIR/supervisor.pid"
  SERVER_PID_FILE="$DASH_DIR/server.pid"
  STOP_FLAG="$DASH_DIR/stop"
  SERVER_LOG="$DASH_DIR/server.log"
  SUPERVISOR_LOG="$DASH_DIR/supervisor.log"
}

# Bind address safety: never wildcard.
# On success sets DASH_BIND=ip:port and returns 0.
# On failure prints to stderr and returns 1 (never call die from a subshell).
resolve_bind() {
  local raw ip port ts_ip
  DASH_BIND=
  mkdir -p "$CONFIG" || {
    printf 'fm-dashboard: cannot create config dir: %s\n' "$CONFIG" >&2
    return 1
  }
  if [ -f "$CONFIG/dashboard-bind" ]; then
    raw=$(head -n 1 "$CONFIG/dashboard-bind" | tr -d '[:space:]')
  else
    raw=
  fi
  if [ -z "$raw" ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
      printf 'fm-dashboard: no config/dashboard-bind and tailscale is not on PATH; write config/dashboard-bind (e.g. 127.0.0.1:8391) for local/dev\n' >&2
      return 1
    fi
    ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 | tr -d '[:space:]')
    if [ -z "$ts_ip" ]; then
      printf 'fm-dashboard: tailscale ip -4 returned empty; write config/dashboard-bind or bring Tailscale up\n' >&2
      return 1
    fi
    raw="${ts_ip}:${DEFAULT_PORT}"
  fi
  # Reject wildcards before splitting so bare :: and 0.0.0.0:* never parse oddly.
  case "$raw" in
    0.0.0.0|0.0.0.0:*|::|::*|\[::\]|\[::\]:*|\*|\[::0\]|\[::0\]:*)
      printf 'fm-dashboard: refusing wildcard bind address %s (use a Tailscale IP or 127.0.0.1 for dev)\n' "$raw" >&2
      return 1
      ;;
  esac
  case "$raw" in
    *:*)
      ip=${raw%:*}
      port=${raw##*:}
      ;;
    *)
      ip=$raw
      port=$DEFAULT_PORT
      ;;
  esac
  case "$ip" in
    ''|0.0.0.0|::|\[::\]|\*|\[::0\])
      printf 'fm-dashboard: refusing wildcard bind address %s (use a Tailscale IP or 127.0.0.1 for dev)\n' "$ip" >&2
      return 1
      ;;
  esac
  case "$port" in
    ''|*[!0-9]*)
      printf 'fm-dashboard: invalid port in dashboard-bind: %s\n' "$raw" >&2
      return 1
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    printf 'fm-dashboard: port out of range in dashboard-bind: %s\n' "$port" >&2
    return 1
  fi
  DASH_BIND="${ip}:${port}"
  return 0
}

# On success prints token on stdout. On failure returns 1 with message on stderr.
ensure_token() {
  local token_file token
  mkdir -p "$CONFIG" || {
    printf 'fm-dashboard: cannot create config dir: %s\n' "$CONFIG" >&2
    return 1
  }
  token_file="$CONFIG/dashboard-token"
  if [ -f "$token_file" ]; then
    token=$(tr -d '[:space:]' <"$token_file")
    if [ -z "$token" ]; then
      printf 'fm-dashboard: config/dashboard-token exists but is empty\n' >&2
      return 1
    fi
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    token=$(openssl rand -hex 32)
  elif [ -r /dev/urandom ]; then
    # Portable fallback without openssl or any scripting language.
    token=$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  else
    printf 'fm-dashboard: cannot generate token (need openssl or /dev/urandom)\n' >&2
    return 1
  fi
  if [ -z "$token" ] || [ "${#token}" -lt 32 ]; then
    printf 'fm-dashboard: token generation produced an empty or short secret\n' >&2
    return 1
  fi
  umask 077
  printf '%s\n' "$token" >"$token_file" || {
    printf 'fm-dashboard: cannot write %s\n' "$token_file" >&2
    return 1
  }
  chmod 600 "$token_file" || {
    printf 'fm-dashboard: cannot chmod 600 %s\n' "$token_file" >&2
    return 1
  }
  printf '%s\n' "$token"
}

pid_alive() {
  local pid=$1
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

read_pid() {
  local file=$1
  [ -f "$file" ] || { printf '\n'; return 0; }
  tr -d '[:space:]' <"$file"
}

# True when the supervisor process for this home is alive.
supervisor_running() {
  local pid
  pid=$(read_pid "$SUPERVISOR_PID_FILE")
  pid_alive "$pid"
}

server_running() {
  local pid
  pid=$(read_pid "$SERVER_PID_FILE")
  pid_alive "$pid"
}

# Build the Rust release binary when absent. Documents cargo as a requirement.
ensure_server_binary() {
  if [ -x "$SERVER_BIN" ]; then
    return 0
  fi
  command -v cargo >/dev/null 2>&1 ||
    die "cargo not found; install a Rust toolchain to build the dashboard server (see docs/dashboard.md)"
  [ -f "$DASH_CRATE_DIR/Cargo.toml" ] ||
    die "missing dashboard crate: $DASH_CRATE_DIR/Cargo.toml"
  printf 'fm-dashboard: building release binary (cargo build --release)...\n' >&2
  if ! (
    cd "$DASH_CRATE_DIR" || exit 1
    cargo build --release
  ); then
    die "cargo build --release failed in $DASH_CRATE_DIR"
  fi
  [ -x "$SERVER_BIN" ] || die "build finished but binary missing: $SERVER_BIN"
}

prepare_runtime() {
  require_home
  [ -d "$STATIC_DIR" ] || die "missing static UI: $STATIC_DIR"
  ensure_server_binary
  mkdir -p "$DASH_DIR" || die "cannot create $DASH_DIR"
  # Dashboard may write only under state/dashboard/ (and create config for
  # token/bind). Never touch other state or data files.
}

# TCP readiness without scripting languages.
port_open() {
  local host=$1 port=$2
  if command -v curl >/dev/null 2>&1; then
    curl -sS -o /dev/null --connect-timeout 0.2 --max-time 0.5 \
      "http://${host}:${port}/healthz" 2>/dev/null
    return $?
  fi
  # bash /dev/tcp when available
  (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1
}

# Export server env in the current shell; set DASH_BIND.
# Returns non-zero on bind/token failure (messages already on stderr).
assign_server_env() {
  local token
  resolve_bind || return 1
  token=$(ensure_token) || return 1
  FM_DASHBOARD_BIND_HOST=${DASH_BIND%:*}
  FM_DASHBOARD_BIND_PORT=${DASH_BIND##*:}
  FM_DASHBOARD_TOKEN=$token
  FM_DASHBOARD_STATIC=$STATIC_DIR
  FM_DASHBOARD_SNAPSHOT=$FM_ROOT/bin/fm-fleet-snapshot.sh
  export FM_HOME FM_ROOT_OVERRIDE="$FM_ROOT"
  export FM_DASHBOARD_BIND_HOST FM_DASHBOARD_BIND_PORT FM_DASHBOARD_TOKEN
  export FM_DASHBOARD_STATIC FM_DASHBOARD_SNAPSHOT
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    export FM_STATE_OVERRIDE
  fi
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    export FM_DATA_OVERRIDE
  fi
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    export FM_CONFIG_OVERRIDE
  fi
  return 0
}

cmd_run() {
  prepare_runtime
  assign_server_env || exit 1
  printf 'fm-dashboard: running in foreground on http://%s (FM_HOME=%s)\n' "$DASH_BIND" "$FM_HOME" >&2
  # Foreground: no supervisor loop. Ctrl-C stops the server.
  exec "$SERVER_BIN"
}

supervisor_loop() {
  # Runs as the daemonized supervisor. Restarts the server quickly on exit
  # unless the stop flag is present.
  local rc
  : >"$STOP_FLAG.tmp"
  rm -f "$STOP_FLAG"
  while true; do
    if [ -f "$STOP_FLAG" ]; then
      break
    fi
    "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 &
    printf '%s\n' "$!" >"$SERVER_PID_FILE"
    wait "$!" || rc=$?
    rc=${rc:-0}
    if [ -f "$STOP_FLAG" ]; then
      break
    fi
    {
      printf '%s supervisor: server exited rc=%s; restarting within 1s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
    } >>"$SUPERVISOR_LOG"
    sleep 1
  done
  rm -f "$SERVER_PID_FILE"
}

cmd_start() {
  prepare_runtime
  if supervisor_running; then
    if ! assign_server_env; then
      # Still report already-running even if bind file is now broken.
      printf 'fm-dashboard: already running (supervisor pid %s); bind config currently unreadable\n' \
        "$(read_pid "$SUPERVISOR_PID_FILE")"
      return 0
    fi
    printf 'fm-dashboard: already running (supervisor pid %s) on http://%s\n' \
      "$(read_pid "$SUPERVISOR_PID_FILE")" "$DASH_BIND"
    return 0
  fi
  # Reclaim stale pid files from a dead supervisor.
  rm -f "$SUPERVISOR_PID_FILE" "$SERVER_PID_FILE" "$STOP_FLAG"
  assign_server_env || exit 1
  : >>"$SERVER_LOG"
  : >>"$SUPERVISOR_LOG"
  # Daemonize the supervisor loop so firstmate session exit never reaps it.
  (
    export FM_HOME FM_ROOT_OVERRIDE FM_DASHBOARD_BIND_HOST FM_DASHBOARD_BIND_PORT
    export FM_DASHBOARD_TOKEN FM_DASHBOARD_STATIC FM_DASHBOARD_SNAPSHOT
    [ -n "${FM_STATE_OVERRIDE:-}" ] && export FM_STATE_OVERRIDE
    [ -n "${FM_DATA_OVERRIDE:-}" ] && export FM_DATA_OVERRIDE
    [ -n "${FM_CONFIG_OVERRIDE:-}" ] && export FM_CONFIG_OVERRIDE
    # Close stdio so the caller is not held; logs go to files.
    exec </dev/null >>"$SUPERVISOR_LOG" 2>&1
    supervisor_loop
  ) &
  printf '%s\n' "$!" >"$SUPERVISOR_PID_FILE"
  # Brief readiness wait so status/tests see a live server.
  local i=0
  while [ "$i" -lt 50 ]; do
    if server_running; then
      break
    fi
    # Also accept a listening port as ready even if pid write races.
    if port_open "$FM_DASHBOARD_BIND_HOST" "$FM_DASHBOARD_BIND_PORT"; then
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if ! supervisor_running; then
    die "supervisor failed to stay up; see $SUPERVISOR_LOG"
  fi
  printf 'fm-dashboard: started on http://%s (supervisor pid %s, FM_HOME=%s)\n' \
    "$DASH_BIND" "$(read_pid "$SUPERVISOR_PID_FILE")" "$FM_HOME"
  printf 'fm-dashboard: token in %s/dashboard-token (mode 0600); Authorization: Bearer <token>\n' \
    "$CONFIG"
}

cmd_stop() {
  local spid spid2
  prepare_runtime
  # Signal the loop first so a death does not restart the server.
  : >"$STOP_FLAG"
  if server_running; then
    kill "$(read_pid "$SERVER_PID_FILE")" 2>/dev/null || true
  fi
  if supervisor_running; then
    spid=$(read_pid "$SUPERVISOR_PID_FILE")
    kill "$spid" 2>/dev/null || true
    # Give the loop a moment to exit cleanly.
    local i=0
    while [ "$i" -lt 30 ] && pid_alive "$spid"; do
      i=$((i + 1))
      sleep 0.1
    done
    if pid_alive "$spid"; then
      kill -9 "$spid" 2>/dev/null || true
    fi
  fi
  # Reap a lingering server after supervisor death.
  if server_running; then
    spid2=$(read_pid "$SERVER_PID_FILE")
    kill -9 "$spid2" 2>/dev/null || true
  fi
  rm -f "$SUPERVISOR_PID_FILE" "$SERVER_PID_FILE" "$STOP_FLAG"
  printf 'fm-dashboard: stopped\n'
}

cmd_status() {
  local bind
  prepare_runtime
  if resolve_bind 2>/dev/null; then
    bind=$DASH_BIND
  else
    # Still report process state even if bind cannot be resolved.
    bind="(unresolved)"
  fi
  if supervisor_running; then
    printf 'fm-dashboard: running\n'
    printf '  supervisor_pid: %s\n' "$(read_pid "$SUPERVISOR_PID_FILE")"
    if server_running; then
      printf '  server_pid: %s\n' "$(read_pid "$SERVER_PID_FILE")"
    else
      printf '  server_pid: (restarting or not yet written)\n'
    fi
    printf '  bind: %s\n' "$bind"
    printf '  fm_home: %s\n' "$FM_HOME"
    printf '  url: http://%s/\n' "$bind"
    printf '  log: %s\n' "$SERVER_LOG"
    return 0
  fi
  printf 'fm-dashboard: stopped\n'
  printf '  bind: %s\n' "$bind"
  printf '  fm_home: %s\n' "$FM_HOME"
  return 1
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    start) shift; cmd_start "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    status) shift; cmd_status "$@" ;;
    run) shift; cmd_run "$@" ;;
    "") usage >&2; exit 2 ;;
    *) usage >&2; die "unknown command: $1" ;;
  esac
}

main "$@"
