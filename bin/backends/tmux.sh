#!/usr/bin/env bash
# tmux session-provider adapter. This file is sourced by fm-backend.sh.
# The command shapes intentionally match the pre-abstraction JT scripts.

# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

fm_backend_tmux_send_key() {  # <target> <key>
  tmux send-keys -t "$1" "$2"
}

fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

fm_backend_tmux_submit_enter() {  # <target> <retries> <enter-sleep>
  fm_tmux_submit_enter_core "$@"
}

fm_backend_tmux_pane_readable() {  # <target>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

fm_backend_tmux_composer_state() {  # <target>
  fm_tmux_composer_state "$@"
}

fm_backend_tmux_container_ensure() {  # <cwd ignored>
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    if ! tmux has-session -t firstmate 2>/dev/null; then
      tmux new-session -d -s firstmate || return 1
    fi
    printf 'firstmate'
  fi
}

fm_backend_tmux_create_task() {  # <session> <window-name> <project-dir> -> window id
  local ses=$1 wname=$2 proj_abs=$3
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs"
}

fm_backend_tmux_list_task_ids() {  # <session>
  tmux list-windows -t "$1" -F '#{window_id}'
}

fm_backend_tmux_set_task_option() {  # <target> <option> <value>
  tmux set-window-option -t "$1" "$2" "$3"
}

fm_backend_tmux_rename_task() {  # <target> <name>
  tmux rename-window -t "$1" "$2"
}

fm_backend_tmux_task_name() {  # <target>
  tmux display-message -p -t "$1" '#{window_name}'
}

fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi
  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  comm=${comm#-}
  case "$comm" in
    *claude*|*codex*|*opencode*|*grok*|*pi*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    '') printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

fm_backend_tmux_kill() {  # <target>
  local target=$1 windows window_id window_target
  tmux kill-window -t "$target" 2>/dev/null && return 0
  windows=$(tmux list-windows -a -F '#{window_id}|#{session_name}:#{window_name}' 2>/dev/null) || return 1
  while IFS='|' read -r window_id window_target; do
    case "$target" in
      @*) [ "$window_id" = "$target" ] || continue ;;
      *) [ "$window_target" = "$target" ] || continue ;;
    esac
    return 1
  done <<EOF
$windows
EOF
  return 0
}
