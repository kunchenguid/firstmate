#!/usr/bin/env bash
# Resolve or persist the WorkGraph parallelism mode used by new admissions.
#
# Usage:
#   fm-parallelism.sh get [--request MODE] [--goal ID] [--project ID]
#   fm-parallelism.sh set MODE [--goal ID | --project ID]
#   fm-parallelism.sh status [--request MODE] [--goal ID] [--project ID]
#
# schemas/workgraph/parallelism-v1.json owns the persisted vocabulary.
# auto is accepted only as a command-line alias and is canonicalized to on.
# FM_PARALLELISM_OVERRIDE and persisted files accept canonical values only.
# Writes use an atomic same-directory rename independently of task lifecycle and never read or change active task metadata.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,12{s/^# //;p;}' "$0"
}

die() {
  printf 'fm-parallelism: %s\n' "$*" >&2
  exit 1
}

safe_id() {
  local LC_ALL=C
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

safe_goal_id() {
  local LC_ALL=C
  safe_id "$1" || return 1
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

canonical_mode() {
  case "$1" in
    off|eco|on|max) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

cli_mode() {
  case "$1" in
    auto) printf 'on\n' ;;
    *) canonical_mode "$1" ;;
  esac
}

require_cli_mode() {
  local raw=$1 canonical
  canonical=$(cli_mode "$raw") || die "invalid mode '$raw'; expected off|eco|on|max (auto aliases on)"
  printf '%s\n' "$canonical"
}

require_canonical_mode() {
  local raw=$1 canonical
  canonical=$(canonical_mode "$raw") || die "invalid mode '$raw'; expected off|eco|on|max"
  printf '%s\n' "$canonical"
}

parse_id() {
  local kind=$1 value=$2
  case "$kind" in
    goal) safe_goal_id "$value" ;;
    project) safe_id "$value" ;;
    *) return 1 ;;
  esac || die "unsafe $kind id '$value'"
}

REQUEST_MODE=
REQUEST_SOURCE=
GOAL_ID=
PROJECT_ID=
SET_MODE=
COMMAND=${1:-}
[ "$COMMAND" = -h ] || [ "$COMMAND" = --help ] && { usage; exit 0; }
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request)
      [ "$#" -ge 2 ] || die '--request requires a mode'
      [ -z "$REQUEST_SOURCE" ] || die '--request may be supplied once'
      REQUEST_MODE=$(require_cli_mode "$2")
      REQUEST_SOURCE=cli
      shift 2
      ;;
    --request=*)
      [ -z "$REQUEST_SOURCE" ] || die '--request may be supplied once'
      REQUEST_MODE=$(require_cli_mode "${1#*=}")
      REQUEST_SOURCE=cli
      shift
      ;;
    --goal|--goal-id)
      [ "$#" -ge 2 ] || die "$1 requires an id"
      [ -z "$GOAL_ID" ] || die 'goal selector may be supplied once'
      GOAL_ID=$2
      parse_id goal "$GOAL_ID"
      shift 2
      ;;
    --goal=*|--goal-id=*)
      [ -z "$GOAL_ID" ] || die 'goal selector may be supplied once'
      GOAL_ID=${1#*=}
      parse_id goal "$GOAL_ID"
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] || die '--project requires an id'
      [ -z "$PROJECT_ID" ] || die 'project selector may be supplied once'
      PROJECT_ID=$2
      parse_id project "$PROJECT_ID"
      shift 2
      ;;
    --project=*)
      [ -z "$PROJECT_ID" ] || die 'project selector may be supplied once'
      PROJECT_ID=${1#*=}
      parse_id project "$PROJECT_ID"
      shift
      ;;
    off|eco|on|max|auto)
      [ -z "$SET_MODE" ] || die 'mode may be supplied once'
      SET_MODE=$(require_cli_mode "$1")
      shift
      ;;
    *) die "unknown argument '$1'; use --help" ;;
  esac
done

case "$COMMAND" in
  get|status)
    [ -z "$SET_MODE" ] || die "$COMMAND does not accept a positional mode"
    ;;
  set)
    [ -n "$SET_MODE" ] || die 'set requires a mode'
    [ -z "$REQUEST_SOURCE" ] || die '--request applies only to get and status'
    [ -z "$GOAL_ID" ] || [ -z "$PROJECT_ID" ] || die 'set accepts either --goal or --project, not both'
    ;;
  *) die "unknown command '$COMMAND'; use get, set, or status" ;;
esac

if [ -z "$REQUEST_SOURCE" ] && [ -n "${FM_PARALLELISM_OVERRIDE:-}" ]; then
  REQUEST_MODE=$(require_canonical_mode "$FM_PARALLELISM_OVERRIDE")
  REQUEST_SOURCE=environment
fi

GLOBAL_FILE="$CONFIG_DIR/parallelism"
PROJECT_FILE=
GOAL_FILE=
[ -n "$PROJECT_ID" ] && PROJECT_FILE="$CONFIG_DIR/parallelism-projects/$PROJECT_ID"
[ -n "$GOAL_ID" ] && GOAL_FILE="$DATA_DIR/workgraphs/$GOAL_ID/parallelism"

read_persisted() {
  local path=$1 label=$2 value
  [ ! -L "$path" ] || die "$label configuration is not a regular file: $path"
  if [ ! -e "$path" ]; then
    return 1
  fi
  [ -f "$path" ] || die "$label configuration is not a regular file: $path"
  value=$(awk 'NR == 1 { first=$0; next } { bad=1 } END { if (bad || NR != 1) exit 2; print first }' "$path") \
    || die "malformed $label configuration: $path"
  [ -n "$value" ] || die "malformed $label configuration: $path"
  canonical_mode "$value" >/dev/null \
    || die "unknown $label mode '$value' in $path"
  PERSISTED_MODE=$value
  return 0
}

require_publishable_target() {
  local path=$1
  [ ! -L "$path" ] || die "configuration target is not a regular file: $path"
  if [ -e "$path" ]; then
    [ -f "$path" ] || die "configuration target is not a regular file: $path"
  fi
}

publish_mode() {
  local path=$1 value=$2 dir tmp
  require_publishable_target "$path"
  dir=$(dirname "$path")
  mkdir -p "$dir" || die "cannot create configuration directory: $dir"
  tmp=$(mktemp "$dir/.parallelism.tmp.XXXXXX") || die "cannot create atomic temporary file in $dir"
  if ! printf '%s\n' "$value" > "$tmp"; then
    rm -f "$tmp"
    die "cannot write temporary configuration in $dir"
  fi
  require_publishable_target "$path"
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    die "cannot publish configuration atomically at $path"
  fi
}

if [ "$COMMAND" = set ]; then
  if [ -n "$GOAL_ID" ]; then
    publish_mode "$GOAL_FILE" "$SET_MODE"
    printf '%s\n' "$SET_MODE"
  elif [ -n "$PROJECT_ID" ]; then
    publish_mode "$PROJECT_FILE" "$SET_MODE"
    printf '%s\n' "$SET_MODE"
  else
    publish_mode "$GLOBAL_FILE" "$SET_MODE"
    printf '%s\n' "$SET_MODE"
  fi
  exit 0
fi

RESOLVED_MODE=
RESOLVED_SOURCE=default
REQUEST_DISPLAY=${REQUEST_MODE:-absent}
GOAL_DISPLAY=absent
PROJECT_DISPLAY=absent
GLOBAL_DISPLAY=absent

if [ -n "$REQUEST_MODE" ]; then
  RESOLVED_MODE=$REQUEST_MODE
  RESOLVED_SOURCE=request
  [ -z "$GOAL_FILE" ] || GOAL_DISPLAY=uninspected
  [ -z "$PROJECT_FILE" ] || PROJECT_DISPLAY=uninspected
  GLOBAL_DISPLAY=uninspected
else
  if [ -n "$GOAL_FILE" ] && read_persisted "$GOAL_FILE" goal; then
    GOAL_DISPLAY=$PERSISTED_MODE
  fi
  if [ -n "$PROJECT_FILE" ] && read_persisted "$PROJECT_FILE" project; then
    PROJECT_DISPLAY=$PERSISTED_MODE
  fi
  if read_persisted "$GLOBAL_FILE" global; then
    GLOBAL_DISPLAY=$PERSISTED_MODE
  fi
  if [ "$GOAL_DISPLAY" != absent ]; then
    RESOLVED_MODE=$GOAL_DISPLAY
    RESOLVED_SOURCE=goal
  elif [ "$PROJECT_DISPLAY" != absent ]; then
    RESOLVED_MODE=$PROJECT_DISPLAY
    RESOLVED_SOURCE=project
  elif [ "$GLOBAL_DISPLAY" != absent ]; then
    RESOLVED_MODE=$GLOBAL_DISPLAY
    RESOLVED_SOURCE=global
  fi
fi

[ -n "$RESOLVED_MODE" ] || RESOLVED_MODE=on

if [ "$COMMAND" = get ]; then
  printf '%s\n' "$RESOLVED_MODE"
else
  printf 'mode=%s\n' "$RESOLVED_MODE"
  printf 'source=%s\n' "$RESOLVED_SOURCE"
  printf 'request=%s\n' "$REQUEST_DISPLAY"
  printf 'goal=%s\n' "$GOAL_DISPLAY"
  printf 'project=%s\n' "$PROJECT_DISPLAY"
  printf 'global=%s\n' "$GLOBAL_DISPLAY"
  printf 'enforcement=disabled\n'
fi
