# shellcheck shell=bash
# Immutable remote execution identity retained after provider-state cleanup.
# This receipt owns no goal, progress, acceptance, scheduling or retry policy.

fm_remote_execution_receipt_record() { # <data-dir> <task> <executor> <provider> <generation>
  local data=$1 task=$2 executor=$3 provider=$4 generation=$5 dir path tmp current
  [ -n "$task" ] && [ -n "$executor" ] && [ -n "$provider" ] && [ -n "$generation" ] || return 2
  dir="$data/$task"
  path="$dir/remote-execution.json"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  current=$(jq -cn --arg task "$task" --arg executor "$executor" --arg provider "$provider" \
    --arg generation "$generation" \
    '{schema:"fm-remote-execution-receipt.v1",task_id:$task,executor:$executor,provider:$provider,execution_generation:$generation}')
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path")" = 1 ] \
      && jq -e --argjson current "$current" '. == $current' "$path" >/dev/null 2>&1
    return $?
  fi
  tmp=$(umask 077; mktemp "$dir/.remote-execution.XXXXXX") || return 1
  printf '%s\n' "$current" >"$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$path" || {
    rm -f "$tmp"
    return 1
  }
}

fm_remote_execution_receipt_guard() { # <data-dir> <task>
  local path="$1/$2/remote-execution.json"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] \
    && jq -e --arg task "$2" '
      .schema == "fm-remote-execution-receipt.v1" and .task_id == $task and
      (.executor | type == "string" and length > 0) and
      (.provider | type == "string" and length > 0) and
      (.execution_generation | type == "string" and length > 0)
    ' "$path" >/dev/null 2>&1 || {
      echo "REFUSED: task $2 has unsafe retained remote execution identity" >&2
      return 6
    }
  echo "REFUSED: task $2 already has a retained remote execution identity; use a separately authorized new task" >&2
  return 6
}
