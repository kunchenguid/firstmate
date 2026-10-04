#!/usr/bin/env bash
# Merge-owner receipts for exact task execution generations.
# New receipts live beside other task runtime state. Historical lifecycle.json
# receipts are read-only compatibility evidence and are never enrolled, updated,
# or treated as task progress.

FM_MERGE_RECEIPT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_merge_receipt_file() { # <task>
  printf '%s/%s.merge-receipts.jsonl\n' "${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}" "$1"
}

fm_merge_receipt_archive_file() { # <task>
  printf '%s/%s/merge-receipts.jsonl\n' "${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}" "$1"
}

fm_merge_receipt_validate_value() { # <label> <value>
  if [ -z "$2" ] || printf '%s' "$2" | grep -q '[[:cntrl:]]'; then
    printf 'REFUSED: merge receipt %s is empty or contains control bytes\n' "$1" >&2
    return 1
  fi
}

fm_merge_receipt_read_file() { # <path>
  local file=$1
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -c %h "$file" 2>/dev/null || stat -f %l "$file")" = 1 ] || {
    echo 'REFUSED: merge receipt history is not a regular single-link file' >&2
    return 1
  }
  [ -s "$file" ] || { echo 'REFUSED: merge receipt history is empty' >&2; return 1; }
  jq -ce 'if .schema=="fm-merge-receipt.v1" and (.task_id|type)=="string" and
    (.execution_generation|type)=="string" and (.url|type)=="string" and (.head|type)=="string"
    then . else error("invalid merge receipt row") end' "$file"
}

fm_merge_receipt_history() { # <task>
  local id=$1 state data file archive historical current_status rows
  state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}
  data=${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}
  file=$(fm_merge_receipt_file "$id") || return 1
  archive=$(fm_merge_receipt_archive_file "$id") || return 1
  rows=$({ fm_merge_receipt_read_file "$archive" && fm_merge_receipt_read_file "$file"; }) || return 1
  historical="$data/$id/lifecycle.json"
  # Retained rich data is a last-resort immutable receipt source only after the
  # configured ordinary owner proves that no current task row exists.
  # shellcheck source=bin/fm-task-progress-lib.sh
  . "$FM_MERGE_RECEIPT_BIN/fm-task-progress-lib.sh"
  if fm_task_progress_current_absent "$id"; then
    current_status=0
  else
    current_status=$?
  fi
  [ "$current_status" -ne 2 ] || return 1
  if [ "$current_status" -eq 0 ] && [ -f "$historical" ] && [ ! -L "$historical" ]; then
    rows=$(printf '%s\n' "$rows"; jq -c --arg id "$id" '
      if (.schema=="fm-task-lifecycle.v1" or .schema=="fm-task-lifecycle.v2") and .task_id==$id then
        [.owner_receipts.merge[]? |
          select((.execution_generation|type)=="string" and (.facts.url|type)=="string" and (.facts.head|type)=="string") |
          {schema:"fm-merge-receipt.v1",task_id:$id,execution_generation:.execution_generation,
           url:.facts.url,head:.facts.head,historical:true}][]
      else error("invalid historical lifecycle record") end' "$historical") || return 1
  fi
  printf '%s\n' "$rows" | jq -sc '
    reduce .[] as $row ([];
      if any(.[]; [.task_id,.execution_generation,.url,.head] ==
                   [$row.task_id,$row.execution_generation,$row.url,$row.head])
      then . else . + [$row] end) | .[]'
}

fm_merge_receipt_archive() { # <task>; move complete active history out of routine state scans
  local id=$1 file archive task_dir tmp
  file=$(fm_merge_receipt_file "$id") || return 1
  archive=$(fm_merge_receipt_archive_file "$id") || return 1
  [ -e "$file" ] || [ -L "$file" ] || return 0
  fm_merge_receipt_read_file "$file" >/dev/null || return 1
  task_dir=${archive%/*}
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || {
    echo 'REFUSED: merge receipt task evidence directory is unsafe' >&2
    return 1
  }
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    fm_merge_receipt_read_file "$archive" >/dev/null || return 1
  fi
  tmp=$(umask 077; mktemp "$task_dir/.merge-receipts.XXXXXX") || return 1
  {
    if [ -f "$archive" ]; then sed -n 'p' "$archive"; fi
    sed -n 'p' "$file"
  } | jq -sc '
    reduce .[] as $row ([];
      if any(.[]; [.task_id,.execution_generation,.url,.head] ==
                   [$row.task_id,$row.execution_generation,$row.url,$row.head])
      then . else . + [$row] end) | .[]' > "$tmp" || {
    rm -f "$tmp"; return 1;
  }
  if [ ! -s "$tmp" ] || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$archive"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f -- "$file"
}

fm_merge_receipt_record() { # <task> <generation> <url> <head>
  local id=$1 generation=$2 url=$3 head=$4 file state tmp current matches conflicts
  fm_merge_receipt_validate_value generation "$generation" || return 1
  fm_merge_receipt_validate_value url "$url" || return 1
  fm_merge_receipt_validate_value head "$head" || return 1
  state=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}
  file=$(fm_merge_receipt_file "$id") || return 1
  mkdir -p "$state" || return 1
  current=$(fm_merge_receipt_history "$id") || return 1
  matches=$(printf '%s\n' "$current" | jq -sc --arg generation "$generation" --arg url "$url" --arg head "$head" \
    '[.[] | select(.execution_generation==$generation and .url==$url and .head==$head)] | length') || return 1
  [ "$matches" -le 1 ] || { echo 'REFUSED: duplicate merge receipt identity is ambiguous' >&2; return 1; }
  [ "$matches" -eq 0 ] || return 0
  conflicts=$(printf '%s\n' "$current" | jq -sc --arg generation "$generation" --arg url "$url" --arg head "$head" \
    '[.[] | select(.execution_generation==$generation and ((.url==$url and .head!=$head) or (.head==$head and .url!=$url)))] | length') || return 1
  [ "$conflicts" -eq 0 ] || { echo 'REFUSED: conflicting merge receipt identity for current execution' >&2; return 1; }
  tmp=$(umask 077; mktemp "$state/.${id}.merge-receipts.XXXXXX") || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || { rm -f "$tmp"; return 1; }
    cp "$file" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  jq -cn --arg id "$id" --arg generation "$generation" --arg url "$url" --arg head "$head" \
    '{schema:"fm-merge-receipt.v1",task_id:$id,execution_generation:$generation,url:$url,head:$head}' >> "$tmp" || {
      rm -f "$tmp"; return 1;
    }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

fm_merge_receipt_current() { # <task> <generation> [url] [head]
  local id=$1 generation=$2 url=${3:-} head=${4:-} history
  history=$(fm_merge_receipt_history "$id") || return 1
  printf '%s\n' "$history" | jq -sc --arg generation "$generation" --arg url "$url" --arg head "$head" '
    [.[] | select(.execution_generation==$generation) |
      select(($url=="" or .url==$url) and ($head=="" or .head==$head))] |
    if length==1 then .[0]
    elif length==0 then error("missing current-generation merge receipt")
    else error("ambiguous current-generation merge receipt") end'
}
