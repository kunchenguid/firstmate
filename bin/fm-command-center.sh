#!/usr/bin/env bash
# Open a visual command center for this firstmate home.
#
# The command center creates a separate tmux session with:
#   - a dashboard window showing active tasks and last status lines
#   - linked live windows for each active crewmate/secondmate pane
#
# Linked tmux windows are live views of the original panes. This script never
# moves crewmate panes, never tears them down, and never writes to projects.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/fm-command-center.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"
SESSION="${FM_COMMAND_CENTER_SESSION:-firstmate-command}"
DASHBOARD_WINDOW="${FM_COMMAND_CENTER_DASHBOARD:-bridge}"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  cat <<EOF
Usage: fm-command-center.sh [open|split|refresh|status]

Commands:
  open      create/refresh the command center and attach to it (default)
  split     open the dashboard in a split pane in the current tmux window
  refresh   create/refresh the command center without attaching
  status    print the command center session and active linked windows

Environment:
  FM_COMMAND_CENTER_SESSION    tmux session name (default: firstmate-command)
  FM_COMMAND_CENTER_SPLIT      split direction: h or v (default: h)
  FM_COMMAND_CENTER_SPLIT_SIZE split percentage (default: 38)
  NO_COLOR                     disable ANSI color
  FORCE_COLOR/CLICOLOR_FORCE   force ANSI color for non-interactive output
EOF
}

command=${1:-open}
case "$command" in
  open|split|refresh|status|__dashboard_loop|__dashboard_once|-h|--help) ;;
  *) usage >&2; exit 2 ;;
esac
case "$command" in
  -h|--help) usage; exit 0 ;;
esac

use_color=0
if [ -z "${NO_COLOR:-}" ]; then
  if [ -t 1 ]; then
    use_color=1
  elif [ -n "${FORCE_COLOR:-}" ] || [ -n "${CLICOLOR_FORCE:-}" ]; then
    use_color=1
  fi
fi

ansi() {
  [ "$use_color" -eq 1 ] || return 0
  printf '\033[%sm' "$1"
}

reset=$(ansi 0)
bold=$(ansi 1)
dim=$(ansi 2)
cyan=$(ansi 36)
blue=$(ansi 34)
magenta=$(ansi 35)
green=$(ansi 32)
yellow=$(ansi 33)
red=$(ansi 31)

paint() {
  color=$1
  shift
  printf '%s%s%s' "$color" "$*" "$reset"
}

paint_state() {
  state=$1
  case "$state" in
    active|ready) paint "$green" "$state" ;;
    working) paint "$yellow" "$state" ;;
    idle) paint "$green" "$state" ;;
    missing|failed|blocked) paint "$red" "$state" ;;
    *) printf '%s' "$state" ;;
  esac
}

tmux_available() {
  command -v tmux >/dev/null 2>&1
}

session_exists() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF "$SESSION"
}

meta_value() {
  key=$1
  file=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

task_title() {
  id=$1
  [ -f "$DATA/backlog.md" ] || { printf '%s' "$id"; return 0; }
  line=$(grep -E "^- \\[[ x]\\] $id - " "$DATA/backlog.md" 2>/dev/null | head -1 || true)
  [ -n "$line" ] || { printf '%s' "$id"; return 0; }
  printf '%s' "$line" | sed -E "s/^- \\[[ x]\\] $id - //; s/ \\(repo:.*$//"
}

last_status() {
  id=$1
  status_file="$STATE/$id.status"
  [ -f "$status_file" ] || { printf 'no status yet'; return 0; }
  grep -v '^[[:space:]]*$' "$status_file" | tail -1 | sed -E 's/[[:space:]]+/ /g'
}

pane_state() {
  target=$1
  if ! tmux display-message -p -t "$target" '#{window_id}' >/dev/null 2>&1; then
    printf 'missing'
    return 0
  fi
  if tmux capture-pane -p -t "$target" -S -8 2>/dev/null \
      | grep -v '^[[:space:]]*$' \
      | tail -6 \
      | grep -qiE 'esc (to )?interrupt|Working\.\.\.'; then
    printf 'working'
  else
    printf 'idle'
  fi
}

divider() {
  printf '%s\n' "$(paint "$dim" '-----------------')"
}

label() {
  printf '%s' "$(paint "$dim" "$1")"
}

dashboard() {
  clear 2>/dev/null || true
  printf '%s\n' "$(paint "$bold$cyan" 'FIRSTMATE COMMAND CENTER')"
  printf '%s %s\n' "$(label 'Home:')" "$FM_HOME"
  printf '%s %s\n\n' "$(label 'Time:')" "$(date '+%Y-%m-%d %H:%M:%S')"

  printf '%s\n' "$(paint "$bold$magenta" 'Active Crewmates')"
  divider
  found=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    window=$(meta_value window "$meta")
    project=$(meta_value project "$meta")
    kind=$(meta_value kind "$meta")
    mode=$(meta_value mode "$meta")
    [ -n "$window" ] || continue
    found=1
    state=$(pane_state "$window")
    printf '%s\n' "$(paint "$bold$blue" "$id")"
    printf '  %s  %s\n' "$(label 'title:')" "$(task_title "$id")"
    printf '  %s   %s (%s)\n' "$(label 'pane:')" "$window" "$(paint_state "$state")"
    printf '  %s   %s\n' "$(label 'kind:')" "${kind:-unknown}"
    printf '  %s   %s\n' "$(label 'mode:')" "${mode:-unknown}"
    if [ -n "$project" ]; then
      printf '  %s   %s\n' "$(label 'repo:')" "$(basename "$project")"
    fi
    printf '  %s %s\n\n' "$(label 'status:')" "$(last_status "$id")"
  done
  [ "$found" -eq 1 ] || printf '%s\n\n' "$(paint "$yellow" "No active crewmates recorded in $STATE/*.meta")"

  printf '%s\n' "$(paint "$bold$magenta" 'Controls')"
  divider
  printf '  %s status-window names to switch live views\n' "$(label 'mouse click')"
  printf '  %s            scroll dashboard or crewmate output\n' "$(label 'mouse scroll')"
  printf '  %s        focus a pane if panes are split later\n' "$(label 'mouse click pane')"
  printf '  %s      choose a live crewmate window\n' "$(label 'tmux prefix + w')"
  printf '  %s    next/previous window\n' "$(label 'tmux prefix + n/p')"
  printf '  %s      detach from command center\n' "$(label 'tmux prefix + d')"
  printf '  %s   steer a crewmate\n\n' "$(label 'bin/fm-send.sh fm-<task-id> <instruction>')"
  printf '%s\n' "$(paint "$dim" 'This dashboard refreshes every 5 seconds. Linked crewmate windows are live.')"
}

run_dashboard_loop() {
  while :; do
    dashboard
    sleep 5
  done
}

ensure_session() {
  if ! session_exists; then
    tmux new-session -d -s "$SESSION" -n "$DASHBOARD_WINDOW" \
      "$SCRIPT_PATH" __dashboard_loop
  elif ! tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qxF "$DASHBOARD_WINDOW"; then
    tmux new-window -d -t "$SESSION" -n "$DASHBOARD_WINDOW" \
      "$SCRIPT_PATH" __dashboard_loop
  else
    tmux respawn-pane -k -t "$SESSION:$DASHBOARD_WINDOW" \
      "$SCRIPT_PATH" __dashboard_loop
  fi

  tmux set-option -t "$SESSION" status-left ' firstmate command '
  tmux set-option -t "$SESSION" status-left-style 'fg=cyan,bold'
  tmux set-option -t "$SESSION" status-right '#(date "+%H:%M") '
  tmux set-option -t "$SESSION" status-right-style 'fg=green'
  tmux set-option -t "$SESSION" window-status-current-style 'fg=black,bg=cyan,bold'
  tmux set-option -g mouse on
}

link_active_windows() {
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    source_window=$(meta_value window "$meta")
    [ -n "$source_window" ] || continue
    if ! tmux display-message -p -t "$source_window" '#{window_id}' >/dev/null 2>&1; then
      continue
    fi
    source_id=$(tmux display-message -p -t "$source_window" '#{window_id}')
    existing=$(tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -xF "$source_id" || true)
    [ -n "$existing" ] && continue
    tmux link-window -s "$source_window" -t "$SESSION:" 2>/dev/null || true
  done
}

print_status() {
  printf 'session: %s\n' "$SESSION"
  if ! session_exists; then
    printf 'state: %s\n' "$(paint_state missing)"
    return 0
  fi
  printf 'state: %s\n' "$(paint_state ready)"
  tmux list-windows -t "$SESSION" -F 'window: #{window_name}'
}

open_split() {
  direction=${FM_COMMAND_CENTER_SPLIT:-h}
  size=${FM_COMMAND_CENTER_SPLIT_SIZE:-38}
  target=${FM_COMMAND_CENTER_SPLIT_TARGET:-}
  [ -n "$target" ] || target=$(tmux display-message -p '#{session_name}:#{window_name}')
  tmux set-option -g mouse on
  case "$direction" in
    v) flag=-v ;;
    *) flag=-h ;;
  esac
  tmux split-window "$flag" -p "$size" -t "$target" "$SCRIPT_PATH __dashboard_loop"
}

if [ "$command" = "__dashboard_loop" ]; then
  run_dashboard_loop
  exit 0
fi

if [ "$command" = "__dashboard_once" ]; then
  dashboard
  exit 0
fi

tmux_available || { echo "error: tmux is required" >&2; exit 1; }

case "$command" in
  status)
    print_status
    ;;
  refresh)
    ensure_session
    link_active_windows
    print_status
    ;;
  split)
    open_split
    ;;
  open)
    ensure_session
    link_active_windows
    tmux attach-session -t "$SESSION"
    ;;
esac
