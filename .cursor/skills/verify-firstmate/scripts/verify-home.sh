#!/usr/bin/env bash
# verify-home.sh - isolate one Firstmate verification home for this run.
#
# Firstmate is an agent distro, not a long-running HTTP app.
# Isolation is per FM_HOME: two homes may run side by side, but one home
# may not be double-driven.
# This helper refuses the live code-root home and only tears down the
# scratch home and child pids that this run recorded.
#
# Usage:
#   verify-home.sh init
#   verify-home.sh env
#   verify-home.sh launch
#   verify-home.sh doctor
#   verify-home.sh cleanup
#
# Environment:
#   VERIFY_FIRSTMATE_EVIDENCE  optional evidence root; default
#                              /tmp/verify-firstmate-evidence/<run-id>
#   VERIFY_FIRSTMATE_RUN_FILE  optional run-record path; default
#                              /tmp/verify-firstmate.run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_code_root() {
  local d
  d="$(cd "$SCRIPT_DIR" && pwd)"
  while [ "$d" != / ]; do
    if [ -f "$d/AGENTS.md" ] && [ -x "$d/bin/fm-session-start.sh" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  echo "verify-home: cannot find Firstmate code root from $SCRIPT_DIR" >&2
  return 1
}

CODE_ROOT="$(find_code_root)"
RUN_FILE="${VERIFY_FIRSTMATE_RUN_FILE:-/tmp/verify-firstmate.run}"

same_path() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd)" || return 1
  [ "$a" = "$b" ]
}

refuse_live_home() {
  local home=$1
  if same_path "$home" "$CODE_ROOT"; then
    echo "verify-home: refusing to drive the live code-root home $CODE_ROOT" >&2
    echo "verify-home: one home has one session lock; create a scratch home with init" >&2
    return 1
  fi
}

load_run() {
  [ -f "$RUN_FILE" ] || {
    echo "verify-home: no run record at $RUN_FILE; run init first" >&2
    return 1
  }
  # shellcheck disable=SC1090
  . "$RUN_FILE"
  [ -n "${VERIFY_HOME:-}" ] || {
    echo "verify-home: run record missing VERIFY_HOME" >&2
    return 1
  }
  [ -n "${EVIDENCE:-}" ] || {
    echo "verify-home: run record missing EVIDENCE" >&2
    return 1
  }
  refuse_live_home "$VERIFY_HOME"
}

write_run() {
  umask 077
  cat > "$RUN_FILE" <<EOF
VERIFY_HOME=$VERIFY_HOME
VERIFY_RUN_ID=$VERIFY_RUN_ID
EVIDENCE=$EVIDENCE
CODE_ROOT=$CODE_ROOT
EOF
}

cmd_init() {
  if [ -f "$RUN_FILE" ]; then
    # shellcheck disable=SC1090
    . "$RUN_FILE"
    if [ -n "${VERIFY_HOME:-}" ] && [ -d "$VERIFY_HOME" ]; then
      echo "verify-home: a scratch home is already recorded at $VERIFY_HOME" >&2
      echo "verify-home: run cleanup before init, or this run will strand that home" >&2
      return 1
    fi
  fi
  VERIFY_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  VERIFY_HOME="${TMPDIR:-/tmp}/verify-firstmate-home-$VERIFY_RUN_ID"
  EVIDENCE="${VERIFY_FIRSTMATE_EVIDENCE:-/tmp/verify-firstmate-evidence/$VERIFY_RUN_ID}"
  refuse_live_home "$VERIFY_HOME"
  mkdir -p "$VERIFY_HOME/state" "$VERIFY_HOME/data" "$VERIFY_HOME/config" "$VERIFY_HOME/projects" "$EVIDENCE"
  write_run
  printf 'VERIFY_HOME=%s\n' "$VERIFY_HOME"
  printf 'EVIDENCE=%s\n' "$EVIDENCE"
  printf 'VERIFY_RUN_ID=%s\n' "$VERIFY_RUN_ID"
}

cmd_env() {
  load_run
  printf 'export FM_HOME=%q\n' "$VERIFY_HOME"
  printf 'export EVIDENCE=%q\n' "$EVIDENCE"
  printf 'export VERIFY_RUN_ID=%q\n' "$VERIFY_RUN_ID"
  printf 'export CODE_ROOT=%q\n' "$CODE_ROOT"
}

cmd_launch() {
  load_run
  mkdir -p "$VERIFY_HOME/state" "$VERIFY_HOME/data" "$VERIFY_HOME/config" "$VERIFY_HOME/projects"
  # Unset overrides that could leak the live home into this launch.
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_ROOT_OVERRIDE \
    FM_HOME="$VERIFY_HOME" \
    "$CODE_ROOT/bin/fm-session-start.sh"
}

cmd_doctor() {
  load_run
  local lock_out completion network_pid watch_pid
  if [ ! -d "$VERIFY_HOME" ]; then
    echo "doctor: FAIL home missing: $VERIFY_HOME" >&2
    return 1
  fi
  refuse_live_home "$VERIFY_HOME"
  lock_out="$(env -u FM_STATE_OVERRIDE FM_HOME="$VERIFY_HOME" "$CODE_ROOT/bin/fm-lock.sh" status)"
  printf 'doctor: home %s\n' "$VERIFY_HOME"
  printf 'doctor: lock %s\n' "$lock_out"
  if [ -f "$VERIFY_HOME/state/.session-start-complete" ]; then
    completion="$(tr -d '\n' < "$VERIFY_HOME/state/.session-start-complete")"
    printf 'doctor: session-start-complete pid=%s\n' "$completion"
  else
    echo "doctor: FAIL session-start-complete missing (launch first)" >&2
    return 1
  fi
  case "$lock_out" in
    *'held by live harness pid'*) ;;
    *)
      echo "doctor: FAIL expected a live harness lock on the scratch home" >&2
      return 1
      ;;
  esac
  network_pid="$(sed -n 's/^pid=//p' "$VERIFY_HOME/state/.startup-network.status" 2>/dev/null | tail -1 || true)"
  if [ -n "$network_pid" ]; then
    if kill -0 "$network_pid" 2>/dev/null; then
      printf 'doctor: startup-network worker pid=%s live (owned by this home status file)\n' "$network_pid"
    else
      printf 'doctor: startup-network worker pid=%s not running\n' "$network_pid"
    fi
  else
    echo "doctor: startup-network worker not recorded yet"
  fi
  watch_pid="$(cat "$VERIFY_HOME/state/.watch.lock/pid" 2>/dev/null || true)"
  if [ -n "$watch_pid" ]; then
    printf 'doctor: watcher pid=%s recorded in this home lock\n' "$watch_pid"
  else
    echo "doctor: no watcher lock in this home"
  fi
  echo "doctor: PASS"
}

kill_recorded_pid() {
  local label=$1 pid=$2
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$pid" = "$$" ] || [ "$pid" = "${PPID:-}" ]; then
    echo "verify-home: refusing to kill this shell or its parent ($label pid=$pid)" >&2
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'cleanup: %s pid=%s already gone\n' "$label" "$pid"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'cleanup: stopped %s pid=%s\n' "$label" "$pid"
      return 0
    fi
    sleep 0.2
  done
  echo "verify-home: $label pid=$pid still live after TERM; sending KILL" >&2
  kill -KILL "$pid" 2>/dev/null || true
}

cmd_cleanup() {
  if [ ! -f "$RUN_FILE" ]; then
    echo "verify-home: nothing to clean (no run record)"
    return 0
  fi
  # shellcheck disable=SC1090
  . "$RUN_FILE"
  if [ -z "${VERIFY_HOME:-}" ]; then
    echo "verify-home: run record missing VERIFY_HOME" >&2
    return 1
  fi
  if same_path "$VERIFY_HOME" "$CODE_ROOT"; then
    echo "verify-home: refusing to delete the live code-root home" >&2
    return 1
  fi
  if [ -n "${EVIDENCE:-}" ]; then
    printf 'cleanup: leaving evidence at %s\n' "$EVIDENCE"
  fi
  if [ -d "$VERIFY_HOME" ]; then
    local network_pid watch_pid
    network_pid="$(sed -n 's/^pid=//p' "$VERIFY_HOME/state/.startup-network.status" 2>/dev/null | tail -1 || true)"
    watch_pid="$(cat "$VERIFY_HOME/state/.watch.lock/pid" 2>/dev/null || true)"
    kill_recorded_pid startup-network "$network_pid"
    kill_recorded_pid watcher "$watch_pid"
    rm -rf "$VERIFY_HOME"
    printf 'cleanup: removed scratch home %s\n' "$VERIFY_HOME"
  else
    echo "cleanup: scratch home already absent"
  fi
  rm -f "$RUN_FILE"
  echo "cleanup: run record removed"
}

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

case "${1:-}" in
  init) cmd_init ;;
  env) cmd_env ;;
  launch) cmd_launch ;;
  doctor) cmd_doctor ;;
  cleanup) cmd_cleanup ;;
  -h|--help|help|'') usage ;;
  *)
    echo "verify-home: unknown command: $1 (try --help)" >&2
    exit 2
    ;;
esac
