#!/usr/bin/env bash
# Translate AGY's documented PreInvocation/Stop hook payloads into the existing
# generation-bound busy contract. No user/global configuration is changed.
# Usage: fm-agy-hook.sh <PreInvocation|Stop> <state-dir> <id> <gen> <worktree>
# stdin: AGY hook JSON. stdout: an empty JSON object, including on refusal.
# Only the first PreInvocation may bind a conversation for this generation;
# subagent/other-conversation events and mismatched workspaces are ignored.
# Stop closes the turn only when fullyIdle is the JSON boolean true. A manual
# Escape emits no Stop in AGY 1.2.1; it cannot be represented as a completed turn.
# Each generation owns state/<id>.agy-hook/<gen>.conversation, so an old hook
# cannot poison a replacement's first-conversation binding. Cleanup is owned
# by fm-control-lib's wiring paths and fm-teardown.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

apply_hook() {
  [ "$#" -eq 5 ] || return 1
  local event=$1 state=$2 id=$3 gen=$4 worktree=$5 payload conversation binding current saved
  case "$event" in PreInvocation|Stop) ;; *) return 1 ;; esac
  fm_busy_token_valid "$id" && fm_busy_token_valid "$gen" || return 1
  current=$(fm_busy_current_gen "$state" "$id") || return 1
  [ "$current" = "$gen" ] || return 1
  payload=$(jq -ce --arg wt "$worktree" '
    select(type == "object") |
    select(.workspacePaths | type == "array" and index($wt) != null) |
    select(.conversationId | type == "string" and test("^[A-Za-z0-9-]+$"))
  ') || return 1
  conversation=$(printf '%s' "$payload" | jq -r .conversationId) || return 1
  binding="$state/$id.agy-hook/$gen.conversation"
  [ ! -L "$state/$id.agy-hook" ] && [ -d "$state/$id.agy-hook" ] || return 1
  [ ! -L "$binding" ] || return 1
  if [ "$event" = PreInvocation ] && [ ! -e "$binding" ]; then
    # noclobber makes competing writers converge without replacing the owner.
    (umask 077; set -C; printf '%s\t%s\n' "$gen" "$conversation" > "$binding") 2>/dev/null || true
  fi
  IFS= read -r saved < "$binding" || return 1
  [ "$saved" = "$gen"$'\t'"$conversation" ] || return 1
  if [ "$event" = PreInvocation ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source agy-hook --event pre-invocation
  else
    printf '%s' "$payload" | jq -e '.fullyIdle == true' >/dev/null || return 1
    "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source agy-hook --event stop || return 1
    touch "$state/$id.turn-ended"
  fi
}
apply_hook "$@" >/dev/null 2>&1 || true
printf '{}\n'
