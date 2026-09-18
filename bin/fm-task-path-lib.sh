#!/usr/bin/env bash
# Canonical owner for per-task artifact paths.
#
# New task artifacts live under data/tasks/<task-id>.
# Reads use a canonical artifact when present and otherwise consult the one
# legacy data/<task-id> location, while writes and recorded links always use the
# canonical path.
# Home-global files such as data/backlog.md and data/projects.md, and data
# directories that are not task records, stay with their existing callers.
#
# Usage: . bin/fm-task-path-lib.sh
#   fm_task_dir <data-dir> <task-id>
#   fm_task_legacy_dir <data-dir> <task-id>
#   fm_task_path <data-dir> <task-id> <artifact-relative-path>
#   fm_task_read_path <data-dir> <task-id> <artifact-relative-path>
#   fm_task_relpath <task-id> <artifact-relative-path>

fm_task_path_id_valid() {  # <task-id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_task_path_relative_valid() {  # <artifact-relative-path>
  local rel=${1-}
  case "$rel" in
    ''|/*|.|./*|*/./*|*/../*|../*|*/..|..|*$'\n'*|*$'\r'*) return 1 ;;
  esac
}

fm_task_path_data_root() {  # <data-dir>
  case "$1" in
    /) printf '/\n' ;;
    */) printf '%s\n' "${1%/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_task_dir() {  # <data-dir> <task-id>
  local data id
  data=$(fm_task_path_data_root "$1") || return 1
  id=$2
  fm_task_path_id_valid "$id" || return 1
  printf '%s/tasks/%s\n' "$data" "$id"
}

fm_task_legacy_dir() {  # <data-dir> <task-id>
  local data id
  data=$(fm_task_path_data_root "$1") || return 1
  id=$2
  fm_task_path_id_valid "$id" || return 1
  printf '%s/%s\n' "$data" "$id"
}

fm_task_path() {  # <data-dir> <task-id> <artifact-relative-path>
  local dir=$1 id=$2 rel=$3
  dir=$(fm_task_dir "$dir" "$id") || return 1
  fm_task_path_relative_valid "$rel" || return 1
  printf '%s/%s\n' "$dir" "$rel"
}

fm_task_read_path() {  # <data-dir> <task-id> <artifact-relative-path>
  local data=$1 id=$2 rel=$3 canonical legacy canonical_dir canonical_root legacy_dir
  canonical=$(fm_task_path "$data" "$id" "$rel") || return 1
  legacy=$(fm_task_legacy_dir "$data" "$id") || return 1
  canonical_dir=${canonical%/*}
  canonical_root=${canonical_dir%/*}
  legacy_dir=${legacy%/*}
  [ ! -L "$canonical_root" ] || return 1
  [ ! -L "$canonical_dir" ] || return 1
  [ ! -L "$legacy_dir" ] || return 1
  [ ! -L "$legacy" ] || return 1
  if [ -d "$canonical_root" ] && [ -d "$canonical_dir" ] \
     && [ -e "$canonical" ] && [ ! -L "$canonical" ]; then
    printf '%s\n' "$canonical"
  else
    printf '%s/%s\n' "$legacy" "$rel"
  fi
}

fm_task_relpath() {  # <task-id> <artifact-relative-path>
  local id=$1 rel=$2
  fm_task_path_id_valid "$id" || return 1
  fm_task_path_relative_valid "$rel" || return 1
  printf 'data/tasks/%s/%s\n' "$id" "$rel"
}

fm_task_legacy_relpath() {  # <task-id> <artifact-relative-path>
  local id=$1 rel=$2
  fm_task_path_id_valid "$id" || return 1
  fm_task_path_relative_valid "$rel" || return 1
  printf 'data/%s/%s\n' "$id" "$rel"
}

fm_task_legacy_entries() {  # <data-dir>
  local data=$1 entry
  for entry in "$data"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    printf '%s\n' "$entry"
  done
}

fm_task_artifact_paths() {  # <data-dir> <artifact-relative-path>
  local data=$1 rel=$2 dir id canonical path
  fm_task_path_relative_valid "$rel" || return 1
  if [ -d "$data/tasks" ] && [ ! -L "$data/tasks" ]; then
    for dir in "$data/tasks"/*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      id=${dir##*/}
      fm_task_path_id_valid "$id" || continue
      path=$(fm_task_read_path "$data" "$id" "$rel") || return 1
      [ -e "$path" ] && [ ! -L "$path" ] || continue
      printf '%s\n' "$path"
    done
  fi
  for dir in "$data"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    id=${dir##*/}
    [ "$id" != tasks ] || continue
    fm_task_path_id_valid "$id" || continue
    canonical=$(fm_task_dir "$data" "$id") || return 1
    [ -e "$canonical" ] || [ -L "$canonical" ] || {
      path=$(fm_task_read_path "$data" "$id" "$rel") || return 1
      [ -e "$path" ] && [ ! -L "$path" ] || continue
      printf '%s\n' "$path"
    }
  done
}
