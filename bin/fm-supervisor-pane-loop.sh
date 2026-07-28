#!/usr/bin/env bash
# Render one live zellij supervisor pane for a task until its metadata is gone.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

usage() {
  cat <<'EOF'
usage: fm-supervisor-pane-loop.sh <task-id>

Render a live supervisor pane for one active task until its metadata is gone.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

ID=$1
META="$STATE/$ID.meta"
REFRESH_SECS=${FM_SUPERVISOR_REFRESH_SECS:-5}
PEEK_LINES=${FM_SUPERVISOR_PEEK_LINES:-20}

case "$REFRESH_SECS" in
  ''|*[!0-9]*|0) REFRESH_SECS=5 ;;
esac
case "$PEEK_LINES" in
  ''|*[!0-9]*|0) PEEK_LINES=20 ;;
esac

while [ -f "$META" ]; do
  kind=$(meta_value "$META" kind)
  backend=$(meta_value "$META" backend)
  project=$(meta_value "$META" project)
  state_line=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true
  )
  peek_out=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-peek.sh" "$ID" "$PEEK_LINES" 2>&1 || true
  )
  [ -n "$kind" ] || kind=ship
  [ -n "$backend" ] || backend=tmux
  project=${project##*/}
  [ -n "$project" ] || project=-
  [ -n "$state_line" ] || state_line='state: unknown · source: unavailable'
  [ -n "$peek_out" ] || peek_out='(no pane output available)'

  printf '\033[H\033[2J'
  printf 'Firstmate Supervisor\n'
  printf 'Task: fm-%s\n' "$ID"
  printf 'Kind: %s\n' "$kind"
  printf 'Backend: %s\n' "$backend"
  printf 'Project: %s\n' "$project"
  printf 'Observed: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '%s\n\n' "$state_line"
  printf '%s\n' "$peek_out"
  sleep "$REFRESH_SECS"
done
