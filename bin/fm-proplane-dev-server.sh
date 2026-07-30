#!/usr/bin/env bash
# Start or restart the PropPlane Next.js dev server for one agent worktree/port.
# Usage: fm-proplane-dev-server.sh restart <worktree> <port>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-proplane-dev-server.sh restart <worktree> <port>" >&2
}

[ "${1:-}" = restart ] || { usage; exit 2; }
WORKTREE=${2:?worktree required}
PORT=${3:?port required}
case "$PORT" in ''|*[!0-9]*) echo "invalid port: $PORT" >&2; exit 2 ;; esac
[ -d "$WORKTREE" ] || { echo "missing worktree: $WORKTREE" >&2; exit 1; }

# Linked worktrees do not inherit gitignored env; symlink primary .env.local when absent.
env_primary="${FM_HOME:-$FM_ROOT}/projects/proplane/.env.local"
if [ ! -e "$WORKTREE/.env.local" ] && [ -e "$env_primary" ]; then
  ln -sf "$env_primary" "$WORKTREE/.env.local"
fi

PIDFILE="$STATE/.proplane-dev-${PORT}.pid"
LOG="$STATE/.proplane-dev-${PORT}.log"
TMUX_SESSION="proplane-dev-${PORT}"

stop_tmux() {
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi
}

stop_port() {
  stop_tmux
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  if command -v lsof >/dev/null 2>&1; then
    local holder holder_cmd
    holder=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
    if [ -n "$holder" ]; then
      # Only reclaim the port from a dev server. The unconditional version killed
      # whatever happened to be listening, so an unrelated process that had taken
      # a ladder port was terminated by a restart that never mentioned it.
      holder_cmd=$(ps -o command= -p "$holder" 2>/dev/null || true)
      case "$holder_cmd" in
        *node*|*next*|*npm*)
          kill "$holder" 2>/dev/null || true
          sleep 1
          kill -9 "$holder" 2>/dev/null || true
          ;;
        '')
          : # already gone
          ;;
        *)
          echo "dev-server: port $PORT held by pid $holder ($holder_cmd) — not a dev server, refusing to kill it" >&2
          return 1
          ;;
      esac
    fi
  fi
}

mkdir -p "$STATE"
stop_port || exit 1

if [ ! -x "$WORKTREE/node_modules/.bin/next" ]; then
  echo "dev-server: installing dependencies in $WORKTREE"
  (cd "$WORKTREE" && npm install) || {
    echo "dev-server: npm install failed in $WORKTREE" >&2
    exit 1
  }
fi

cd "$WORKTREE"
export PORT="$PORT"
# Loopback only. These servers load the project's real .env.local (Supabase keys,
# Stripe credentials) and expose Next.js dev-only surfaces such as the error
# overlay and source maps. Binding 0.0.0.0 published all of that to every host on
# whatever network the laptop was joined to, while the whole ladder addresses them
# as http://localhost:<port> and never needs off-box reach.
export HOSTNAME=127.0.0.1

start_via_tmux() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE" \
    "export PORT='$PORT' HOSTNAME=127.0.0.1; exec npm run dev >>'$LOG' 2>&1" || return 1
  local holder
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    holder=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
    [ -n "$holder" ] && break
  done
  [ -n "$holder" ] || return 1
  echo "$holder" >"$PIDFILE"
  echo "dev-server: http://localhost:${PORT} (pid ${holder}, tmux ${TMUX_SESSION}, log ${LOG})"
}

if start_via_tmux; then
  exit 0
fi

# Fallback when tmux is unavailable.
if command -v setsid >/dev/null 2>&1; then
  setsid nohup npm run dev >>"$LOG" 2>&1 </dev/null &
else
  nohup sh -c 'exec npm run dev' >>"$LOG" 2>&1 </dev/null &
fi
dev_pid=$!
echo "$dev_pid" >"$PIDFILE"
disown "$dev_pid" 2>/dev/null || true

sleep 2
if kill -0 "$dev_pid" 2>/dev/null; then
  echo "dev-server: http://localhost:${PORT} (pid ${dev_pid}, log ${LOG})"
  exit 0
fi
echo "dev-server: failed to start on port ${PORT} — see ${LOG}" >&2
exit 1
