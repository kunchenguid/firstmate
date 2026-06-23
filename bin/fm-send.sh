#!/usr/bin/env bash
# Send one line of literal text to a crewmate session, then Enter.
# Usage: fm-send.sh <selector> <text...>
#   <selector> may be a bare firstmate window name (fm-xyz), explicit
#   session:window, or an OpenCode server session id recorded in this home's
#   state/<id>.meta.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

"$SCRIPT_DIR/fm-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta="$STATE/${1#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this firstmate home" >&2
        exit 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window"
      ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_for_selector() {
  local selector=$1 base meta win opencode_session_id
  base=${selector#fm-}
  if [ -f "$STATE/$base.meta" ]; then
    printf '%s\n' "$STATE/$base.meta"
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    win=$(meta_value "$meta" window)
    opencode_session_id=$(meta_value "$meta" opencode_session_id)
    case "$selector" in
      "$win"|fm-"$(basename "$meta" .meta)"|"$opencode_session_id") printf '%s\n' "$meta"; return 0 ;;
      *) case "$win" in *:"$selector"|"$selector") printf '%s\n' "$meta"; return 0 ;; esac ;;
    esac
  done
  return 1
}

opencode_helper() {
  local meta=$1 username password
  shift
  username=$(meta_value "$meta" opencode_server_username)
  password=$(meta_value "$meta" opencode_server_password)
  if [ -n "$password" ]; then
    OPENCODE_SERVER_USERNAME=${username:-opencode} OPENCODE_SERVER_PASSWORD=$password "$FM_ROOT/bin/fm-opencode-server" "$@"
  else
    "$FM_ROOT/bin/fm-opencode-server" "$@"
  fi
}

SELECTOR=$1
META=$(meta_for_selector "$SELECTOR" || true)
if [ -n "$META" ]; then
  BACKEND=$(meta_value "$META" backend)
  [ -n "$BACKEND" ] || BACKEND=tmux
  if [ "$BACKEND" = opencode-server ]; then
    SERVER_URL=$(meta_value "$META" opencode_server_url)
    SESSION_ID=$(meta_value "$META" opencode_session_id)
    [ -n "$SERVER_URL" ] || { echo "error: no opencode_server_url= in $META" >&2; exit 1; }
    [ -n "$SESSION_ID" ] || { echo "error: no opencode_session_id= in $META" >&2; exit 1; }
    shift
    if [ "${1:-}" = "--key" ]; then
      case "${2:-}" in
        Escape|C-c) opencode_helper "$META" interrupt "$SERVER_URL" "$SESSION_ID" >/dev/null ;;
        Enter) opencode_helper "$META" send "$SERVER_URL" "$SESSION_ID" "" >/dev/null ;;
        *) echo "error: unsupported OpenCode server key '${2:-}'" >&2; exit 1 ;;
      esac
    else
      opencode_helper "$META" send "$SERVER_URL" "$SESSION_ID" "$*" >/dev/null
    fi
    exit 0
  fi
  T=$(meta_value "$META" window)
  [ -n "$T" ] || { echo "error: no window recorded in $META" >&2; exit 1; }
else
  T=$(resolve "$SELECTOR")
fi
shift

if [ "${1:-}" = "--key" ]; then
  tmux send-keys -t "$T" "$2"
else
  tmux send-keys -t "$T" -l "$*"
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  tmux send-keys -t "$T" Enter
fi
