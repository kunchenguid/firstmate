#!/usr/bin/env bash
# fm-record-export.sh - export a fixed, versioned set of private fleet records.
#
# Usage:
#   fm-record-export.sh sync
#   fm-record-export.sh archive-task <task-id>
#
# config/record-export-root contains exactly one absolute directory path.
# Without that local config file, sync exits successfully without reading or
# writing export state. Sync copies only the v1 allowlist into <root>/live/.
# Every source must be a regular, non-symlink file below this home, and every
# destination component below the configured root must be a real directory.
# Files are staged beside their destination and atomically replaced with mode
# 0640; directories use 0750. The command has no network or scheduling surface.
# archive-task is teardown's internal transaction boundary. It captures one
# task's metadata, optional live status, and pending/handled inbox records under
# <root>/archive/<task>/<spawn_gen>/, then commits manifest.v1.json last.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG_FILE="$CONFIG/record-export-root"
EXPORT_ROOT=
EXPORT_ROOT_REAL=
DATA_REAL=
STATE_REAL=
ARCHIVE_SOURCE_LIST=

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

path_component_safe() {  # <component>
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

path_has_symlink_component() {  # <absolute-path>
  local path=${1#/} component current=
  while [ -n "$path" ]; do
    component=${path%%/*}
    case "$component" in ''|.|..) return 0 ;; esac
    current="$current/$component"
    [ ! -L "$current" ] || return 0
    case "$path" in */*) path=${path#*/} ;; *) path= ;; esac
  done
  return 1
}

load_export_root() {
  local lines
  if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    return 1
  fi
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] \
    || die "record export config is not a readable regular file: $CONFIG_FILE"
  lines=$(awk 'END { print NR + 0 }' "$CONFIG_FILE") \
    || die "cannot read record export config: $CONFIG_FILE"
  [ "$lines" = 1 ] || die "record export config must contain exactly one line"
  IFS= read -r EXPORT_ROOT < "$CONFIG_FILE" \
    || [ -n "$EXPORT_ROOT" ] \
    || die "record export config is empty"
  case "$EXPORT_ROOT" in /*) ;; *) die "record export root must be absolute" ;; esac
  case "$EXPORT_ROOT" in /) die "record export root must not be the filesystem root" ;; esac
  path_has_symlink_component "$EXPORT_ROOT" \
    && die "record export root contains an unsafe component: $EXPORT_ROOT"
  mkdir -p -- "$EXPORT_ROOT" || die "cannot create record export root: $EXPORT_ROOT"
  [ -d "$EXPORT_ROOT" ] && [ ! -L "$EXPORT_ROOT" ] \
    || die "record export root is not a real directory: $EXPORT_ROOT"
  chmod 0750 "$EXPORT_ROOT" || die "cannot secure record export root: $EXPORT_ROOT"
  EXPORT_ROOT_REAL=$(CDPATH='' cd -- "$EXPORT_ROOT" && pwd -P) \
    || die "cannot resolve record export root: $EXPORT_ROOT"
}

source_root_real() {  # <source-root> <label>
  local root=$1 label=$2 resolved
  [ -d "$root" ] && [ ! -L "$root" ] || die "$label root is not a real directory: $root"
  resolved=$(CDPATH='' cd -- "$root" && pwd -P) || die "cannot resolve $label root: $root"
  printf '%s\n' "$resolved"
}

ensure_export_dir() {  # <relative-directory>
  local relative=$1 dir=$EXPORT_ROOT_REAL component resolved
  while [ -n "$relative" ]; do
    component=${relative%%/*}
    path_component_safe "$component" || die "unsafe export path component: $component"
    dir="$dir/$component"
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
      die "unsafe export directory: $dir"
    fi
    mkdir "$dir" 2>/dev/null || [ -d "$dir" ] || die "cannot create export directory: $dir"
    [ ! -L "$dir" ] || die "unsafe export directory: $dir"
    chmod 0750 "$dir" || die "cannot secure export directory: $dir"
    resolved=$(CDPATH='' cd -- "$dir" && pwd -P) || die "cannot resolve export directory: $dir"
    case "$resolved" in "$EXPORT_ROOT_REAL"/*) ;; *) die "export directory escapes configured root: $dir" ;; esac
    dir=$resolved
    case "$relative" in */*) relative=${relative#*/} ;; *) relative= ;; esac
  done
  printf '%s\n' "$dir"
}

source_file_validate() {  # <source> <source-root-real>
  local source=$1 root_real=$2 parent parent_real
  [ -f "$source" ] && [ ! -L "$source" ] || die "unsafe record export source: $source"
  parent=${source%/*}
  [ -d "$parent" ] && [ ! -L "$parent" ] || die "unsafe record export source directory: $parent"
  parent_real=$(CDPATH='' cd -- "$parent" && pwd -P) \
    || die "cannot resolve record export source directory: $parent"
  case "$parent_real" in "$root_real"|"$root_real"/*) ;; *) die "record export source escapes its home root: $source" ;; esac
}

copy_live_file() {  # <source> <source-root-real> <destination-relative-path>
  local source=$1 source_root=$2 relative=$3 parent_relative destination_dir destination tmp
  source_file_validate "$source" "$source_root"
  parent_relative=${relative%/*}
  destination_dir=$(ensure_export_dir "live/$parent_relative")
  destination="$destination_dir/${relative##*/}"
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    die "unsafe record export destination: $destination"
  fi
  tmp=$(umask 027; mktemp "$destination_dir/.record-export.XXXXXX") \
    || die "cannot stage record export destination: $destination"
  if ! cp -- "$source" "$tmp" || ! chmod 0640 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    die "cannot atomically export record: $relative"
  fi
}

copy_if_present() {  # <source> <source-root-real> <destination-relative-path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    copy_live_file "$1" "$2" "$3"
  fi
}

task_dir_has_live_record() {  # <data-task-directory>
  local dir=$1 file
  for file in "$dir/brief.md" "$dir/report.md" "$dir"/status*.log; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    return 0
  done
  return 1
}

sync_data_records() {
  local entry task file relative
  copy_if_present "$DATA/projects.md" "$DATA_REAL" data/projects.md
  copy_if_present "$DATA/backlog.md" "$DATA_REAL" data/backlog.md
  copy_if_present "$DATA/done-archive.md" "$DATA_REAL" data/done-archive.md
  for entry in "$DATA"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    task_dir_has_live_record "$entry" || continue
    task=${entry##*/}
    path_component_safe "$task" || die "unsafe task directory in record export allowlist: $entry"
    [ -d "$entry" ] && [ ! -L "$entry" ] || die "unsafe task directory in record export allowlist: $entry"
    copy_if_present "$entry/brief.md" "$DATA_REAL" "data/$task/brief.md"
    copy_if_present "$entry/report.md" "$DATA_REAL" "data/$task/report.md"
    for file in "$entry"/status*.log; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      relative=${file##*/}
      path_component_safe "$relative" || die "unsafe status archive name: $file"
      copy_live_file "$file" "$DATA_REAL" "data/$task/$relative"
    done
  done
}

sync_inbox_records() {  # <inbox-directory> <task>
  local inbox=$1 task=$2 subdir file base sequence
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || die "unsafe task inbox in record export allowlist: $inbox"
  for subdir in '' handled; do
    if [ -n "$subdir" ]; then
      if [ ! -e "$inbox/$subdir" ] && [ ! -L "$inbox/$subdir" ]; then
        continue
      fi
      [ -d "$inbox/$subdir" ] && [ ! -L "$inbox/$subdir" ] \
        || die "unsafe task inbox directory in record export allowlist: $inbox/$subdir"
    fi
    for file in "$inbox${subdir:+/$subdir}"/*.msg; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      base=${file##*/}
      sequence=${base%.msg}
      case "$sequence" in ''|*[!0-9]*) die "unknown task inbox artifact in record export allowlist: $file" ;; esac
      copy_live_file "$file" "$STATE_REAL" "state/$task.inbox${subdir:+/$subdir}/$base"
    done
  done
}

sync_state_records() {
  local file base task inbox
  copy_if_present "$STATE/fleet-ledger.jsonl" "$STATE_REAL" state/fleet-ledger.jsonl
  for file in "$STATE"/*.meta; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base=${file##*/}
    task=${base%.meta}
    path_component_safe "$task" || die "unsafe task metadata name in record export allowlist: $file"
    copy_live_file "$file" "$STATE_REAL" "state/$base"
  done
  for file in "$STATE"/*.status; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base=${file##*/}
    task=${base%.status}
    path_component_safe "$task" || die "unsafe task status name in record export allowlist: $file"
    copy_live_file "$file" "$STATE_REAL" "state/$base"
  done
  for inbox in "$STATE"/*.inbox; do
    [ -e "$inbox" ] || [ -L "$inbox" ] || continue
    base=${inbox##*/}
    task=${base%.inbox}
    path_component_safe "$task" || die "unsafe task inbox name in record export allowlist: $inbox"
    sync_inbox_records "$inbox" "$task"
  done
}

sync_records() {
  load_export_root || return 0
  DATA_REAL=$(source_root_real "$DATA" data)
  STATE_REAL=$(source_root_real "$STATE" state)
  sync_data_records
  sync_state_records
}

sha256_file() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "record export requires shasum or sha256sum"
  fi
}

file_bytes() {  # <file>
  wc -c < "$1" | tr -d ' '
}

archive_source_add() {  # <source> <source-relative-name> <archive-relative-name>
  source_file_validate "$1" "$STATE_REAL"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ARCHIVE_SOURCE_LIST" \
    || die "cannot stage record export source list"
}

archive_inbox_sources() {  # <task>
  local task=$1 inbox="$STATE/$task.inbox" subdir file base sequence
  if [ ! -e "$inbox" ] && [ ! -L "$inbox" ]; then
    return 0
  fi
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || die "unsafe task inbox archive source: $inbox"
  for subdir in '' handled; do
    if [ -n "$subdir" ]; then
      if [ ! -e "$inbox/$subdir" ] && [ ! -L "$inbox/$subdir" ]; then
        continue
      fi
      [ -d "$inbox/$subdir" ] && [ ! -L "$inbox/$subdir" ] \
        || die "unsafe task inbox archive directory: $inbox/$subdir"
    fi
    for file in "$inbox${subdir:+/$subdir}"/*.msg; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      base=${file##*/}
      sequence=${base%.msg}
      case "$sequence" in ''|*[!0-9]*) die "unknown task inbox archive artifact: $file" ;; esac
      archive_source_add "$file" "state/$task.inbox${subdir:+/$subdir}/$base" \
        "inbox${subdir:+/$subdir}/$base"
    done
  done
}

archive_sources_collect() {  # <task>
  local task=$1 meta="$STATE/$task.meta" status="$STATE/$task.status"
  [ -e "$meta" ] || [ -L "$meta" ] || die "task metadata is unavailable for record export: $meta"
  archive_source_add "$meta" "state/$task.meta" meta
  if [ -e "$status" ] || [ -L "$status" ]; then
    archive_source_add "$status" "state/$task.status" status
  fi
  archive_inbox_sources "$task"
}

metadata_spawn_gen() {  # <metadata-file>
  awk -F= '
    $1 == "spawn_gen" { count++; value = substr($0, index($0, "=") + 1) }
    END { if (count == 1) print value; else exit 1 }
  ' "$1"
}

archive_generation_validate_contents() {  # <generation-directory> [allow-manifest]
  local generation=$1 allow_manifest=${2:-no} path relative base sequence
  while IFS= read -r -d '' path; do
    relative=${path#"$generation"/}
    if [ -L "$path" ]; then
      die "unsafe record export archive artifact: $path"
    fi
    if [ -d "$path" ]; then
      case "$relative" in inbox|inbox/handled) ;;
        *) die "unknown record export archive directory: $path" ;;
      esac
      continue
    fi
    [ -f "$path" ] || die "unsafe record export archive artifact: $path"
    case "$relative" in
      meta|status) ;;
      manifest.v1.json)
        [ "$allow_manifest" = yes ] || die "record export manifest appeared before commit"
        ;;
      .record-export.*|inbox/.record-export.*|inbox/handled/.record-export.*)
        [ "$allow_manifest" = no ] || die "committed record export archive contains staging files"
        rm -f -- "$path" || die "cannot remove stale record export staging file: $path"
        ;;
      inbox/*.msg|inbox/handled/*.msg)
        base=${relative##*/}
        sequence=${base%.msg}
        case "$sequence" in ''|*[!0-9]*) die "unknown record export archive artifact: $path" ;; esac
        ;;
      *) die "unknown record export archive artifact: $path" ;;
    esac
  done < <(find "$generation" -mindepth 1 -print0)
}

archive_copy_file() {  # <source> <generation-directory> <archive-relative-name>
  local source=$1 generation=$2 relative=$3 parent_relative parent destination tmp
  case "$relative" in */*) parent_relative=${relative%/*}; parent=$(ensure_export_dir "archive/${generation#"$EXPORT_ROOT_REAL/archive/"}/$parent_relative") ;;
    *) parent=$generation ;;
  esac
  destination="$generation/$relative"
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    die "unsafe record export archive destination: $destination"
  fi
  tmp=$(umask 027; mktemp "$parent/.record-export.XXXXXX") \
    || die "cannot stage record export archive: $relative"
  if ! cp -- "$source" "$tmp" || ! chmod 0640 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    die "cannot publish record export archive: $relative"
  fi
}

archive_committed_matches_sources() {  # <generation-directory> <task> <spawn-gen>
  local generation=$1 task=$2 spawn_gen=$3 source source_relative archive_relative bytes digest path relative
  local manifest="$generation/manifest.v1.json" archive_count=0 manifest_count
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  [ "$(grep -cF '"schema": "firstmate-record-export-archive.v1"' "$manifest" || true)" = 1 ] || return 1
  [ "$(grep -cF '"schema_version": 1' "$manifest" || true)" = 1 ] || return 1
  [ "$(grep -cF "\"task\": \"$task\"" "$manifest" || true)" = 1 ] || return 1
  [ "$(grep -cF "\"spawn_gen\": \"$spawn_gen\"" "$manifest" || true)" = 1 ] || return 1
  [ "$(grep -cF '"complete": true' "$manifest" || true)" = 1 ] || return 1
  while IFS= read -r -d '' path; do
    [ -f "$path" ] || continue
    relative=${path#"$generation"/}
    [ "$relative" != manifest.v1.json ] || continue
    case "$relative" in
      meta) source_relative="state/$task.meta" ;;
      status) source_relative="state/$task.status" ;;
      inbox/*.msg|inbox/handled/*.msg) source_relative="state/$task.$relative" ;;
      *) return 1 ;;
    esac
    bytes=$(file_bytes "$path")
    digest=$(sha256_file "$path")
    grep -F "\"source\": \"$source_relative\", \"archive\": \"$relative\", \"bytes\": $bytes, \"sha256\": \"$digest\"" \
      "$manifest" >/dev/null || return 1
    archive_count=$((archive_count + 1))
  done < <(find "$generation" -mindepth 1 -type f -print0)
  manifest_count=$(grep -cF '"source":' "$manifest" || true)
  [ "$archive_count" = "$manifest_count" ] || return 1
  while IFS=$(printf '\t') read -r source source_relative archive_relative; do
    [ -f "$generation/$archive_relative" ] && [ ! -L "$generation/$archive_relative" ] || return 1
    cmp -s "$source" "$generation/$archive_relative" || return 1
    bytes=$(file_bytes "$source")
    digest=$(sha256_file "$source")
    grep -F "\"source\": \"$source_relative\", \"archive\": \"$archive_relative\", \"bytes\": $bytes, \"sha256\": \"$digest\"" \
      "$manifest" >/dev/null || return 1
  done < "$ARCHIVE_SOURCE_LIST"
}

archive_files_match_sources() {  # <generation-directory>
  local generation=$1 source source_relative archive_relative
  while IFS=$(printf '\t') read -r source source_relative archive_relative; do
    cmp -s "$source" "$generation/$archive_relative" || return 1
  done < "$ARCHIVE_SOURCE_LIST"
}

archive_manifest_commit() {  # <generation-directory> <task> <spawn-gen>
  local generation=$1 task=$2 spawn_gen=$3 tmp source source_relative archive_relative
  local bytes digest captured_at first=1
  captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(umask 027; mktemp "$generation/.record-export.manifest.XXXXXX") \
    || die "cannot stage record export archive manifest"
  {
    printf '{\n'
    printf '  "schema": "firstmate-record-export-archive.v1",\n'
    printf '  "schema_version": 1,\n'
    printf '  "task": "%s",\n' "$task"
    printf '  "spawn_gen": "%s",\n' "$spawn_gen"
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "complete": true,\n'
    printf '  "files": [\n'
    while IFS=$(printf '\t') read -r source source_relative archive_relative; do
      bytes=$(file_bytes "$generation/$archive_relative")
      digest=$(sha256_file "$generation/$archive_relative")
      [ "$first" -eq 1 ] || printf ',\n'
      printf '    {"source": "%s", "archive": "%s", "bytes": %s, "sha256": "%s"}' \
        "$source_relative" "$archive_relative" "$bytes" "$digest"
      first=0
    done < "$ARCHIVE_SOURCE_LIST"
    printf '\n  ]\n}\n'
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write record export archive manifest"; }
  chmod 0640 "$tmp" || { rm -f -- "$tmp"; die "cannot secure record export archive manifest"; }
  [ ! -e "$generation/manifest.v1.json" ] && [ ! -L "$generation/manifest.v1.json" ] \
    || { rm -f -- "$tmp"; die "record export archive manifest already exists"; }
  if ! ln -n -- "$tmp" "$generation/manifest.v1.json" \
    || [ -L "$generation/manifest.v1.json" ] \
    || [ ! "$tmp" -ef "$generation/manifest.v1.json" ]; then
    rm -f -- "$tmp"
    die "cannot commit record export archive manifest"
  fi
  rm -f -- "$tmp" || die "cannot retire record export manifest staging file"
}

archive_generation_safe_for_prune() {  # <generation-directory>
  local generation=$1 path relative base sequence
  [ -d "$generation" ] && [ ! -L "$generation" ] || return 1
  while IFS= read -r -d '' path; do
    relative=${path#"$generation"/}
    [ ! -L "$path" ] || return 1
    if [ -d "$path" ]; then
      case "$relative" in inbox|inbox/handled) ;; *) return 1 ;; esac
      continue
    fi
    [ -f "$path" ] || return 1
    case "$relative" in
      meta|status|manifest.v1.json) ;;
      inbox/*.msg|inbox/handled/*.msg)
        base=${relative##*/}
        sequence=${base%.msg}
        case "$sequence" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      *) return 1 ;;
    esac
  done < <(find "$generation" -mindepth 1 -print0)
  return 0
}

archive_prune() {
  local archive_root="$EXPORT_ROOT_REAL/archive" manifest generation relative task spawn_gen
  [ -d "$archive_root" ] && [ ! -L "$archive_root" ] || return 0
  while IFS= read -r -d '' manifest; do
    generation=${manifest%/*}
    relative=${generation#"$archive_root"/}
    case "$relative" in */*) task=${relative%%/*}; spawn_gen=${relative#*/} ;; *) continue ;; esac
    case "$spawn_gen" in */*) continue ;; esac
    if ! path_component_safe "$task" || ! path_component_safe "$spawn_gen" \
      || ! archive_generation_safe_for_prune "$generation"; then
      echo "warning: refusing to prune unsafe record export archive: $generation" >&2
      continue
    fi
    rm -rf -- "$generation" \
      || echo "warning: could not prune record export archive: $generation" >&2
  done < <(find "$archive_root" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.v1.json -mtime +30 -print0 2>/dev/null)
}

archive_task() {  # <task-id>
  local task=$1 meta spawn_gen generation source source_relative archive_relative
  path_component_safe "$task" || die "invalid task id for record export archive: $task"
  load_export_root || return 0
  STATE_REAL=$(source_root_real "$STATE" state)
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "task metadata is unavailable or unsafe for record export: $meta"
  spawn_gen=$(metadata_spawn_gen "$meta") \
    || die "task metadata must contain exactly one spawn_gen for record export: $meta"
  path_component_safe "$spawn_gen" || die "unsafe spawn_gen for record export archive: $spawn_gen"
  ARCHIVE_SOURCE_LIST=$(mktemp "${TMPDIR:-/tmp}/fm-record-export.XXXXXX") \
    || die "cannot stage record export source list"
  trap 'rm -f -- "$ARCHIVE_SOURCE_LIST"' EXIT
  archive_sources_collect "$task"
  generation=$(ensure_export_dir "archive/$task/$spawn_gen")
  if [ -e "$generation/manifest.v1.json" ] || [ -L "$generation/manifest.v1.json" ]; then
    archive_generation_validate_contents "$generation" yes
    archive_committed_matches_sources "$generation" "$task" "$spawn_gen" \
      || die "committed archive differs from current sources: $task/$spawn_gen"
    archive_prune
    return 0
  fi
  archive_generation_validate_contents "$generation" no
  while IFS=$(printf '\t') read -r source source_relative archive_relative; do
    archive_copy_file "$source" "$generation" "$archive_relative"
  done < "$ARCHIVE_SOURCE_LIST"
  archive_files_match_sources "$generation" \
    || die "record export source changed during archive capture: $task/$spawn_gen"
  archive_manifest_commit "$generation" "$task" "$spawn_gen"
  archive_prune
}

[ "$#" -ge 1 ] || usage
command=$1
shift
case "$command:$#" in
  sync:0) sync_records ;;
  archive-task:1) archive_task "$1" ;;
  *) usage ;;
esac
