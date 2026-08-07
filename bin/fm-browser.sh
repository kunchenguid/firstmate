#!/usr/bin/env bash
# Work around the chrome-devtools-axi browser-launch defect with one shared,
# loopback-only headless Chrome per machine and configured debug port.
# Usage:
#   fm-browser.sh url
#   fm-browser.sh status
#   fm-browser.sh stop
#
# `url` probes the debug endpoint before and after taking the machine-scoped
# lock, then prints only a URL that answered /json/version successfully.
# The helper's lock, pidfile, profile, and log are outside every firstmate home.
# Set FM_BROWSER_BIN to select a browser executable, or FM_BROWSER_PORT to use
# another loopback port.  FM_BROWSER_RUNTIME_DIR is an implementation escape
# hatch for isolated tests and machine-local runtime placement.
set -eu

DEFAULT_PORT=9222
PORT=${FM_BROWSER_PORT:-$DEFAULT_PORT}
case "$PORT" in
  ''|*[!0-9]*)
    printf 'fm-browser: invalid FM_BROWSER_PORT: %s\n' "$PORT" >&2
    exit 2
    ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  printf 'fm-browser: FM_BROWSER_PORT must be between 1 and 65535: %s\n' "$PORT" >&2
  exit 2
fi

if [ -n "${FM_BROWSER_RUNTIME_DIR:-}" ]; then
  RUNTIME_DIR=$FM_BROWSER_RUNTIME_DIR
else
  RUNTIME_DIR=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/firstmate-browser-${UID:-$(id -u)}
fi
LOCK_DIR="$RUNTIME_DIR/lock"
PIDFILE="$RUNTIME_DIR/pid"
PROFILE_DIR="$RUNTIME_DIR/profile"
LOGFILE="$RUNTIME_DIR/browser.log"
URL="http://127.0.0.1:$PORT"
LOCK_HELD=0
OWNER_FILE=

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

ensure_runtime_dir() {
  local owner mode permissions current_uid
  current_uid=${UID:-$(id -u)}
  if [ ! -e "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ]; then
    mkdir -p -m 700 "$RUNTIME_DIR"
  fi
  if [ ! -d "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ]; then
    printf 'fm-browser: runtime path is not a real directory: %s\n' "$RUNTIME_DIR" >&2
    return 1
  fi
  owner=$(stat -c '%u' "$RUNTIME_DIR" 2>/dev/null || stat -f '%u' "$RUNTIME_DIR" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$RUNTIME_DIR" 2>/dev/null || stat -f '%Lp' "$RUNTIME_DIR" 2>/dev/null) || return 1
  permissions=$((8#$mode))
  if [ "$owner" != "$current_uid" ] || (( permissions & 0022 )); then
    printf 'fm-browser: runtime directory must be owned by uid %s and not group/other-writable: %s\n' \
      "$current_uid" "$RUNTIME_DIR" >&2
    return 1
  fi
}

release_lock() {
  [ -z "$OWNER_FILE" ] || rm -f "$OWNER_FILE"
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_lock() {
  local attempt=0 owner
  ensure_runtime_dir || return 1
  OWNER_FILE="$RUNTIME_DIR/lock-owner.$$"
  printf '%s\n' "$$" > "$OWNER_FILE"
  trap release_lock EXIT INT TERM
  while :; do
    mkdir "$LOCK_DIR" 2>/dev/null || true
    if ln "$OWNER_FILE" "$LOCK_DIR/pid" 2>/dev/null; then
      rm -f "$OWNER_FILE"
      OWNER_FILE=
      LOCK_HELD=1
      return 0
    fi
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9])
        sleep 0.05
        ;;
      *)
        if kill -0 "$owner" 2>/dev/null; then
          sleep 0.05
        else
          if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$owner" ] &&
            ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$LOCK_DIR/pid"
          fi
        fi
        ;;
    esac
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      printf 'fm-browser: timed out waiting for the machine-scoped browser lock: %s\n' "$LOCK_DIR" >&2
      return 1
    fi
  done
}

probe() {
  local response
  response=$(curl -fsS --connect-timeout 0.2 --max-time 1 "$URL/json/version" 2>/dev/null) || return 1
  case "$response" in
    *webSocketDebuggerUrl*) return 0 ;;
  esac
  return 1
}

sort_cached_candidates() {
  if sort -V </dev/null >/dev/null 2>&1; then
    sort -V -r
  else
    sort -r
  fi
}

cached_binary() {
  local root=$1 candidate
  local -a candidates=()
  shopt -s nullglob
  candidates=( "$root"/*/chrome-linux64/chrome )
  shopt -u nullglob
  [ "${#candidates[@]}" -gt 0 ] || return 1
  while IFS= read -r candidate; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(printf '%s\n' "${candidates[@]}" | sort_cached_candidates)
  return 1
}

discover_binary() {
  local candidate
  if [ -n "${FM_BROWSER_BIN:-}" ] && [ -x "$FM_BROWSER_BIN" ]; then
    printf '%s\n' "$FM_BROWSER_BIN"
    return 0
  fi
  if cached_binary "${HOME:?}/.cache/puppeteer/chrome"; then
    return 0
  fi
  if cached_binary "${HOME:?}/.cache/ms-playwright"; then
    return 0
  fi
  for candidate in google-chrome chromium chromium-browser; do
    candidate=$(command -v "$candidate" 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

pidfile_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$PIDFILE" 2>/dev/null | sed -n '1p'
}

process_args() {
  local pid=$1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline"
  else
    ps -p "$pid" -o args= 2>/dev/null || true
  fi
}

process_starttime() {
  local pid=$1
  [ -r "/proc/$pid/stat" ] || return 0
  awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true
}

owned_pid() {
  local pid recorded_port recorded_profile recorded_start args
  [ -f "$PIDFILE" ] || return 1
  pid=$(pidfile_value pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  recorded_port=$(pidfile_value port)
  recorded_profile=$(pidfile_value profile)
  recorded_start=$(pidfile_value starttime)
  [ "$recorded_port" = "$PORT" ] || return 1
  [ "$recorded_profile" = "$PROFILE_DIR" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -n "$recorded_start" ] && [ "$(process_starttime "$pid")" != "$recorded_start" ]; then
    return 1
  fi
  args=$(process_args "$pid")
  case "$args" in
    *"--remote-debugging-port=$PORT"*"--user-data-dir=$PROFILE_DIR"*)
      printf '%s\n' "$pid"
      return 0
      ;;
  esac
  return 1
}

write_pidfile() {
  local pid=$1 starttime tmp
  starttime=$(process_starttime "$pid")
  tmp="$PIDFILE.$$"
  {
    printf 'pid=%s\n' "$pid"
    printf 'port=%s\n' "$PORT"
    printf 'profile=%s\n' "$PROFILE_DIR"
    printf 'starttime=%s\n' "$starttime"
  } > "$tmp"
  mv -f "$tmp" "$PIDFILE"
}

launch_browser() {
  local binary=$1 pid attempt=0
  mkdir -p "$PROFILE_DIR"
  "$binary" --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
    "--remote-debugging-address=127.0.0.1" "--remote-debugging-port=$PORT" \
    "--user-data-dir=$PROFILE_DIR" about:blank \
    >"$LOGFILE" 2>&1 &
  pid=$!
  write_pidfile "$pid"
  while [ "$attempt" -lt 100 ]; do
    if probe; then
      printf '%s\n' "$URL"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if owned_pid >/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  printf 'fm-browser: Chrome did not expose %s/json/version within 10 seconds.\n' "$URL" >&2
  return 1
}

url() {
  local binary
  if probe; then
    printf '%s\n' "$URL"
    return 0
  fi
  acquire_lock || return 1
  if probe; then
    printf '%s\n' "$URL"
    return 0
  fi
  if ! binary=$(discover_binary); then
    printf 'fm-browser: no Chrome executable found for loopback debugging port %s.\n' "$PORT" >&2
    printf 'fm-browser: install one with: npx -y puppeteer@latest browsers install chrome\n' >&2
    return 1
  fi
  launch_browser "$binary"
}

status() {
  local owner=none
  ensure_runtime_dir || return 1
  if probe; then
    if owned_pid >/dev/null; then
      owner=helper
    else
      owner=external
    fi
    printf 'state=running\nurl=%s\nowner=%s\n' "$URL" "$owner"
    return 0
  fi
  if owned_pid >/dev/null; then
    printf 'state=unreachable\nowner=helper\n'
    return 1
  fi
  printf 'state=stopped\nowner=none\n'
}

stop() {
  local pid attempt=0
  acquire_lock || return 1
  if ! pid=$(owned_pid); then
    rm -f "$PIDFILE"
    printf 'stopped=no-owned-browser\n'
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  while [ "$attempt" -lt 50 ] && owned_pid >/dev/null; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if owned_pid >/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  printf 'stopped=helper-browser\n'
}

case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    usage
    ;;
  url)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    url
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    status
    ;;
  stop)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    stop
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
