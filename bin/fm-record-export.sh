#!/usr/bin/env bash
# fm-record-export.sh - export a fixed, versioned set of private fleet records.
#
# Usage:
#   fm-record-export.sh sync
#
# config/record-export-root contains exactly one absolute directory path.
# Without that local config file, sync exits successfully without reading or
# writing export state. Sync copies only the v1 allowlist into <root>/live/.
# Every source must be a regular, non-symlink file below this home, and every
# destination component below the configured root must be a real directory.
# Files are staged beside their destination and atomically replaced with mode
# 0640; directories use 0750. The command has no network or scheduling surface.
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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

path_component_safe() {  # <component>
  case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

path_has_symlink_component() {  # <absolute-path>
  local path=${1#/} component current=
  while [ -n "$path" ]; do
    component=${path%%/*}
    path_component_safe "$component" || return 0
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

[ "$#" -eq 1 ] || usage
case "$1" in
  sync) sync_records ;;
  *) usage ;;
esac
