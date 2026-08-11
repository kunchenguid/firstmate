#!/usr/bin/env bash
# shellcheck shell=bash

fm_spawn_cleanup_id_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_spawn_cleanup_record_path() {  # <state> <task-id>
  local state=$1 task_id=$2
  fm_spawn_cleanup_id_valid "$task_id" || return 1
  case "$state" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s/.spawn-cleanup/%s.record\n' "$state" "$task_id"
}

fm_spawn_cleanup_record_write() {  # <state> <task-id> <key=value>...
  local state=$1 task_id=$2 record dir tmp line key
  shift 2
  record=$(fm_spawn_cleanup_record_path "$state" "$task_id") || return 1
  dir=${record%/*}
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir -m 700 "$dir" || return 1
  fi
  for line in "$@"; do
    case "$line" in
      ''|*$'\n'*|*$'\r'*|*$'\t'*|*'='*)
        key=${line%%=*}
        case "$key" in
          ''|*[!a-z0-9_]*) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done
  tmp=$(mktemp "$record.XXXXXX") || return 1
  if ! {
    chmod 600 "$tmp" &&
      printf 'version=1\ntask_id=%s\n' "$task_id" > "$tmp" &&
      for line in "$@"; do printf '%s\n' "$line"; done >> "$tmp" &&
      mv -f -- "$tmp" "$record"
  }; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_spawn_cleanup_record_remove() {  # <state> <task-id>
  local record
  record=$(fm_spawn_cleanup_record_path "$1" "$2") || return 1
  if [ -L "$record" ] || [ -f "$record" ]; then
    rm -f -- "$record"
  else
    return 0
  fi
}

fm_spawn_cleanup_record_tasks() {  # <state>
  local dir=$1 record task_id
  [ -d "$dir/.spawn-cleanup" ] && [ ! -L "$dir/.spawn-cleanup" ] || return 0
  for record in "$dir/.spawn-cleanup"/*.record; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    task_id=${record##*/}
    task_id=${task_id%.record}
    fm_spawn_cleanup_id_valid "$task_id" || continue
    printf '%s\n' "$task_id"
  done
}
