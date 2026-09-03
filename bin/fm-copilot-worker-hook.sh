#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=${1:-}
ID=${2:-}
GEN=${3:-}
EVENT=${4:-}
TURNEND=${5:-}

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

[ -n "$STATE_DIR" ] && [ -n "$ID" ] && [ -n "$GEN" ] && [ -n "$EVENT" ] || exit 2
command -v jq >/dev/null 2>&1 || exit 0

COPILOT_WORKER_BINDING_GEN=
COPILOT_WORKER_BINDING_SESSION=

copilot_worker_binding_path() {
  fm_control_copilot_session_path "$STATE_DIR" "$ID"
}

copilot_worker_current_generation_matches() {
  local current_gen
  current_gen=$(cat "$STATE_DIR/$ID.busy-gen" 2>/dev/null || true)
  [ -n "$current_gen" ] && [ "$current_gen" = "$GEN" ]
}

copilot_worker_read_binding() {
  local path=$1 line key value
  COPILOT_WORKER_BINDING_GEN=
  COPILOT_WORKER_BINDING_SESSION=
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      gen) COPILOT_WORKER_BINDING_GEN=$value ;;
      session) COPILOT_WORKER_BINDING_SESSION=$value ;;
    esac
  done < "$path"
  [ -n "$COPILOT_WORKER_BINDING_GEN" ] && [ -n "$COPILOT_WORKER_BINDING_SESSION" ]
}

copilot_worker_binding_matches() {
  local path=$1 session=$2
  copilot_worker_read_binding "$path" || return 1
  [ "$COPILOT_WORKER_BINDING_GEN" = "$GEN" ] || return 1
  [ "$COPILOT_WORKER_BINDING_SESSION" = "$session" ]
}

copilot_worker_bind_session() {
  local path=$1 session=$2 tmp
  if copilot_worker_binding_matches "$path" "$session"; then
    return 0
  fi
  if copilot_worker_read_binding "$path"; then
    if [ "$COPILOT_WORKER_BINDING_GEN" = "$GEN" ]; then
      return 1
    fi
  fi
  rm -f -- "$path" 2>/dev/null || true
  tmp="$STATE_DIR/.$ID.copilot-session.${BASHPID:-$$}.$RANDOM.tmp"
  if ! {
    printf 'gen=%s\n' "$GEN"
    printf 'session=%s\n' "$session"
  } > "$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if ln "$tmp" "$path" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  copilot_worker_binding_matches "$path" "$session"
}

copilot_worker_apply_busy() {
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE_DIR" "$ID" busy \
    --gen "$GEN" --source copilot-hook --event "$EVENT" >/dev/null 2>&1 || true
}

copilot_worker_apply_idle() {
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE_DIR" "$ID" idle \
    --gen "$GEN" --source copilot-hook --event "$EVENT" >/dev/null 2>&1 || true
}

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0
session=$(printf '%s' "$payload" | jq -er '.sessionId | select(type == "string" and length > 0)' 2>/dev/null) || session=
[ -n "$session" ] || exit 0
copilot_worker_current_generation_matches || exit 0
binding=$(copilot_worker_binding_path) || exit 0

case "$EVENT" in
  user-prompt-submitted)
    copilot_worker_bind_session "$binding" "$session" || exit 0
    copilot_worker_apply_busy
    ;;
  agent-stop)
    copilot_worker_binding_matches "$binding" "$session" || exit 0
    [ -n "$TURNEND" ] && touch "$TURNEND" 2>/dev/null || true
    copilot_worker_apply_idle
    ;;
  session-end)
    copilot_worker_binding_matches "$binding" "$session" || exit 0
    copilot_worker_apply_idle
    ;;
  *) exit 2 ;;
esac
