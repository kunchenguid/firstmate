#!/usr/bin/env bash
# fm-dashboard.sh - start the read-only local Firstmate dashboard.
#
# Usage: fm-dashboard.sh start [--port <n>] [--interval <seconds>] [--no-open] [--no-prs]
#        fm-dashboard.sh serve [--port <n>] [--interval <seconds>] [--no-prs]
#
# `start` owns only the dashboard service process and its files under
# `state/.dashboard`; it does not touch fleet locks, wake queues, tasks, or
# endpoints. The service always binds to 127.0.0.1.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DASHBOARD_DIR="$STATE/.dashboard"
PID_FILE="$DASHBOARD_DIR/service.pid"
LISTEN_FILE="$DASHBOARD_DIR/listen.json"
LOG_FILE="$DASHBOARD_DIR/service.log"
PYTHON=${PYTHON:-python3}

usage() {
  cat <<'EOF'
usage: fm-dashboard.sh start [--port <n>] [--interval <seconds>] [--no-open] [--no-prs]
       fm-dashboard.sh serve [--port <n>] [--interval <seconds>] [--no-prs]

Start a read-only Firstmate dashboard on 127.0.0.1 and open it in the default
browser. `serve` is the foreground form for a user-session supervisor or tests.
The service stores its snapshot and append-only dashboard event stream under
state/.dashboard and never consumes state/.wake-queue.
Live PR and CI enrichment is enabled by default; use --no-prs for local-only
operation when GitHub CLI access is unavailable.
EOF
}

command -v "$PYTHON" >/dev/null 2>&1 || { echo "fm-dashboard: python3 not found" >&2; exit 1; }

mode=${1:-}
[ -n "$mode" ] || { usage >&2; exit 2; }
shift

port=${FM_DASHBOARD_PORT:-8765}
interval=${FM_DASHBOARD_INTERVAL:-5}
no_open=0
include_prs=${FM_DASHBOARD_INCLUDE_PRS:-1}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      [ "$#" -gt 1 ] || { echo "fm-dashboard: --port requires a value" >&2; exit 2; }
      port=$2
      shift 2
      ;;
    --port=*) port=${1#--port=} ; shift ;;
    --interval)
      [ "$#" -gt 1 ] || { echo "fm-dashboard: --interval requires a value" >&2; exit 2; }
      interval=$2
      shift 2
      ;;
    --interval=*) interval=${1#--interval=} ; shift ;;
    --no-open) no_open=1; shift ;;
    --no-prs) include_prs=0; shift ;;
    --include-prs) include_prs=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-dashboard: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$port" in ''|*[!0-9]*) echo "fm-dashboard: port must be 0-65535" >&2; exit 2 ;; esac
[ "$port" -le 65535 ] || { echo "fm-dashboard: port must be 0-65535" >&2; exit 2; }
case "$interval" in ''|*[!0-9.]*|.*|*.*.*) echo "fm-dashboard: interval must be a positive number" >&2; exit 2 ;; esac
if ! awk -v value="$interval" 'BEGIN { exit !(value > 0) }'; then
  echo "fm-dashboard: interval must be a positive number" >&2
  exit 2
fi
case "$include_prs" in 0|1) ;; *) echo "fm-dashboard: PR setting must be 0 or 1" >&2; exit 2 ;; esac

mkdir -p "$DASHBOARD_DIR"
chmod 700 "$DASHBOARD_DIR"

if [ "$mode" = serve ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DASHBOARD_INCLUDE_PRS="$include_prs" \
    exec "$PYTHON" "$SCRIPT_DIR/fm-dashboard.py" serve --host 127.0.0.1 --port "$port" --interval "$interval"
fi

[ "$mode" = start ] || { echo "fm-dashboard: expected start or serve" >&2; usage >&2; exit 2; }

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null || true)" 2>/dev/null; then
  :
else
  rm -f "$PID_FILE" "$LISTEN_FILE"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DASHBOARD_INCLUDE_PRS="$include_prs" \
    "$PYTHON" "$SCRIPT_DIR/fm-dashboard.py" serve --host 127.0.0.1 --port "$port" --interval "$interval" \
    >"$LOG_FILE" 2>&1 &
  chmod 600 "$LOG_FILE" 2>/dev/null || true
fi

i=0
url=
while [ "$i" -lt 100 ]; do
  if [ -f "$LISTEN_FILE" ]; then
    url=$(jq -er '.url' "$LISTEN_FILE" 2>/dev/null || true)
    [ -n "$url" ] && break
  fi
  if [ -f "$PID_FILE" ] && ! kill -0 "$(cat "$PID_FILE" 2>/dev/null || true)" 2>/dev/null; then
    echo "fm-dashboard: service failed to start; inspect $LOG_FILE" >&2
    exit 1
  fi
  sleep 0.05
  i=$((i + 1))
done
[ -n "$url" ] || { echo "fm-dashboard: service did not publish a listening URL" >&2; exit 1; }

if [ "$no_open" -eq 0 ] && [ "${FM_DASHBOARD_NO_OPEN:-0}" != 1 ]; then
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v start >/dev/null 2>&1; then
    start "" "$url" >/dev/null 2>&1 || true
  fi
fi

printf 'dashboard: %s\n' "$url"
