#!/usr/bin/env bash
# bin/backends/codex-app.sh - ChatGPT Desktop-visible Codex worker backend.
#
# The installed Codex app-server is the endpoint provider. One headless server
# per Firstmate home listens on a private Unix socket; task targets are durable
# Codex thread ids that also appear in the ChatGPT Desktop task list.

FM_BACKEND_CODEX_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BACKEND_CODEX_APP_ROOT="$(cd "$FM_BACKEND_CODEX_APP_DIR/../.." && pwd)"
FM_BACKEND_CODEX_APP_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_BACKEND_CODEX_APP_ROOT}}"
FM_BACKEND_CODEX_APP_STATE="${FM_STATE_OVERRIDE:-$FM_BACKEND_CODEX_APP_HOME/state}"
FM_BACKEND_CODEX_APP_RUNTIME="$FM_BACKEND_CODEX_APP_STATE/.codex-app"
FM_BACKEND_CODEX_APP_SOCKET="$FM_BACKEND_CODEX_APP_RUNTIME/app-server.sock"
FM_BACKEND_CODEX_APP_PID="$FM_BACKEND_CODEX_APP_RUNTIME/app-server.pid"
FM_BACKEND_CODEX_APP_PID_IDENTITY="$FM_BACKEND_CODEX_APP_RUNTIME/app-server.pid-identity"
FM_BACKEND_CODEX_APP_LOG="$FM_BACKEND_CODEX_APP_RUNTIME/app-server.log"
FM_BACKEND_CODEX_APP_CLIENT="$FM_BACKEND_CODEX_APP_DIR/codex-app-client.mjs"

# Portable lock and process-identity helpers.
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_BACKEND_CODEX_APP_DIR/../fm-wake-lib.sh"

fm_backend_codex_app_codex_bin() {
  if [ -n "${FM_BACKEND_CODEX_APP_CODEX_BIN:-}" ]; then
    printf '%s' "$FM_BACKEND_CODEX_APP_CODEX_BIN"
  else
    command -v codex 2>/dev/null
  fi
}

fm_backend_codex_app_tool_check() {
  local codex_bin
  codex_bin=$(fm_backend_codex_app_codex_bin) || codex_bin=
  [ -n "$codex_bin" ] && [ -x "$codex_bin" ] || {
    echo "error: backend=codex-app selected but the 'codex' CLI is not installed" >&2
    return 1
  }
  command -v node >/dev/null 2>&1 || {
    echo "error: backend=codex-app requires node" >&2
    return 1
  }
  "$codex_bin" app-server --help 2>/dev/null | grep -Fq -- '--listen' || {
    echo "error: backend=codex-app requires a Codex CLI with app-server --listen support" >&2
    return 1
  }
}

fm_backend_codex_app_client() {
  node "$FM_BACKEND_CODEX_APP_CLIENT" "$FM_BACKEND_CODEX_APP_SOCKET" "$@"
}

fm_backend_codex_app_server_ready() {
  [ -S "$FM_BACKEND_CODEX_APP_SOCKET" ] || return 1
  fm_backend_codex_app_client ping >/dev/null 2>&1
}

fm_backend_codex_app_server_pid_live() {
  local pid recorded current
  [ -f "$FM_BACKEND_CODEX_APP_PID" ] && [ ! -L "$FM_BACKEND_CODEX_APP_PID" ] || return 1
  [ -f "$FM_BACKEND_CODEX_APP_PID_IDENTITY" ] && [ ! -L "$FM_BACKEND_CODEX_APP_PID_IDENTITY" ] || return 1
  IFS= read -r pid < "$FM_BACKEND_CODEX_APP_PID" 2>/dev/null || pid=
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  recorded=$(cat "$FM_BACKEND_CODEX_APP_PID_IDENTITY" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$recorded" ]
}

fm_backend_codex_app_server_ensure() {
  local lock codex_bin pid identity current tmp i old_umask
  fm_backend_codex_app_tool_check || return 1
  old_umask=$(umask)
  umask 077
  mkdir -p "$FM_BACKEND_CODEX_APP_RUNTIME"
  umask "$old_umask"
  fm_backend_codex_app_server_ready && return 0

  lock="$FM_BACKEND_CODEX_APP_RUNTIME/start.lock"
  for i in $(seq 1 50); do
    if fm_lock_try_acquire "$lock"; then
      break
    fi
    [ "$i" -lt 50 ] || {
      echo "error: backend=codex-app could not acquire its server-start lock" >&2
      return 1
    }
    sleep 0.1
  done

  if fm_backend_codex_app_server_ready; then
    fm_lock_release "$lock" || true
    return 0
  fi
  if fm_backend_codex_app_server_pid_live; then
    fm_lock_release "$lock" || true
    echo "error: backend=codex-app server process is live but its private socket is not responsive" >&2
    return 1
  fi
  if [ -e "$FM_BACKEND_CODEX_APP_SOCKET" ] || [ -L "$FM_BACKEND_CODEX_APP_SOCKET" ]; then
    if [ -L "$FM_BACKEND_CODEX_APP_SOCKET" ] || [ ! -S "$FM_BACKEND_CODEX_APP_SOCKET" ]; then
      fm_lock_release "$lock" || true
      echo "error: backend=codex-app refuses an unexpected socket path at $FM_BACKEND_CODEX_APP_SOCKET" >&2
      return 1
    fi
    rm -f -- "$FM_BACKEND_CODEX_APP_SOCKET"
  fi
  rm -f -- "$FM_BACKEND_CODEX_APP_PID" "$FM_BACKEND_CODEX_APP_PID_IDENTITY"

  codex_bin=$(fm_backend_codex_app_codex_bin)
  if command -v setsid >/dev/null 2>&1; then
    setsid -f sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
      sh "$FM_BACKEND_CODEX_APP_RUNTIME/app-server.child" \
      "$codex_bin" app-server --listen "unix://$FM_BACKEND_CODEX_APP_SOCKET" \
      </dev/null >"$FM_BACKEND_CODEX_APP_LOG" 2>&1
  else
    ( nohup "$codex_bin" app-server --listen "unix://$FM_BACKEND_CODEX_APP_SOCKET" \
        </dev/null >"$FM_BACKEND_CODEX_APP_LOG" 2>&1 & echo "$!" ) > "$FM_BACKEND_CODEX_APP_RUNTIME/app-server.child"
  fi
  for i in $(seq 1 50); do
    [ -s "$FM_BACKEND_CODEX_APP_RUNTIME/app-server.child" ] && break
    sleep 0.1
  done
  IFS= read -r pid < "$FM_BACKEND_CODEX_APP_RUNTIME/app-server.child" || pid=
  rm -f -- "$FM_BACKEND_CODEX_APP_RUNTIME/app-server.child"
  case "$pid" in
    ''|*[!0-9]*)
      fm_lock_release "$lock" || true
      echo "error: backend=codex-app did not return an app-server pid" >&2
      return 1
      ;;
  esac
  identity=
  for i in $(seq 1 20); do
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || identity=
    sleep 0.05
    current=$(fm_pid_identity "$pid" 2>/dev/null) || current=
    [ -n "$identity" ] && [ "$identity" = "$current" ] && break
    identity=
  done
  if [ -z "$identity" ]; then
    kill "$pid" 2>/dev/null || true
    fm_lock_release "$lock" || true
    echo "error: backend=codex-app could not bind the app-server process identity" >&2
    return 1
  fi
  tmp="$FM_BACKEND_CODEX_APP_PID.tmp.$$"
  printf '%s\n' "$pid" > "$tmp"
  mv "$tmp" "$FM_BACKEND_CODEX_APP_PID"
  tmp="$FM_BACKEND_CODEX_APP_PID_IDENTITY.tmp.$$"
  printf '%s\n' "$identity" > "$tmp"
  mv "$tmp" "$FM_BACKEND_CODEX_APP_PID_IDENTITY"

  for i in $(seq 1 100); do
    if fm_backend_codex_app_server_ready; then
      fm_lock_release "$lock" || true
      return 0
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  fm_lock_release "$lock" || true
  echo "error: backend=codex-app server did not become ready within 10s; inspect $FM_BACKEND_CODEX_APP_LOG" >&2
  return 1
}

fm_backend_codex_app_runtime_check() {
  fm_backend_codex_app_server_ensure
}

fm_backend_codex_app_create_task() {  # <title> <cwd> <model> <effort>
  fm_backend_codex_app_server_ensure || return 1
  fm_backend_codex_app_client create "$@"
}

fm_backend_codex_app_capture() {  # <thread-id> <lines>
  local thread=$1 lines=${2:-40}
  fm_backend_codex_app_client capture "$thread" "$lines"
}

fm_backend_codex_app_send_text_submit() {  # <thread-id> <text> [...ignored terminal timings]
  local thread=$1 text=$2
  fm_backend_codex_app_server_ensure || return 1
  printf '%s' "$text" | fm_backend_codex_app_client send "$thread"
}

fm_backend_codex_app_send_key() {  # <thread-id> <key>
  local thread=$1 key=$2
  case "$key" in
    Escape|C-c) fm_backend_codex_app_server_ensure && fm_backend_codex_app_client interrupt "$thread" ;;
    *) echo "error: backend=codex-app does not support key '$key'" >&2; return 1 ;;
  esac
}

fm_backend_codex_app_kill() {  # <thread-id>
  fm_backend_codex_app_server_ensure || return 1
  fm_backend_codex_app_client archive "$1"
}

fm_backend_codex_app_busy_state() {  # <thread-id>
  fm_backend_codex_app_client state "$1" 2>/dev/null || printf 'unknown'
}

fm_backend_codex_app_target_exists() {  # <thread-id>
  fm_backend_codex_app_client state "$1" >/dev/null 2>&1
}
