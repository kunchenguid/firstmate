#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                         -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                 -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)           -> <mode> on
#   - <name> [<mode> path=/absolute/project] - <desc> (...)   -> path identity for external projects
#
# Path lookups match structured identities only: the canonical in-home
# projects/<name> path, a path= absolute-path token inside the registry
# annotation, or one backtick-wrapped absolute path in the description. They do
# not parse prose such as "at <path>".
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# --path resolves by project directory instead of by name. When a path lookup
# cannot find exactly one project, it fails closed only for malformed or
# ambiguous registered identities; an unknown path keeps the default
# "no-mistakes off" posture and warns.
#
# --with-name prefixes stdout with the resolved registry name:
#   "<name> <mode> <yolo>"
#
# Usage: fm-project-mode.sh [--raw] [--with-name] [--path <project-path>] [<project-name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"
RAW=0
WITH_NAME=0
PATH_ARG=
NAME=

usage() {
  echo "usage: fm-project-mode.sh [--raw] [--with-name] [--path <project-path>] [<project-name>]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1 ;;
    --with-name) WITH_NAME=1 ;;
    --path)
      shift
      [ $# -gt 0 ] || { usage; exit 2; }
      PATH_ARG=$1
      ;;
    --path=*) PATH_ARG=${1#--path=} ;;
    -h|--help) usage; exit 0 ;;
    --*) usage; exit 2 ;;
    *)
      [ -z "$NAME" ] || { usage; exit 2; }
      NAME=$1
      ;;
  esac
  shift
done

[ -n "$NAME" ] || [ -n "$PATH_ARG" ] || { usage; exit 2; }

print_result() {  # <name> <mode> <yolo>
  if [ "$WITH_NAME" -eq 1 ]; then
    printf '%s %s %s\n' "$1" "$2" "$3"
  else
    printf '%s %s\n' "$2" "$3"
  fi
}

default_name() {
  if [ -n "$NAME" ]; then
    printf '%s\n' "$NAME"
    return
  fi
  basename -- "$PATH_ARG"
}

normalize_path() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  if [ -d "$path" ]; then
    cd "$path" && pwd -P
    return
  fi
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path=${path%/}
  done
  printf '%s\n' "$path"
}

registry_line_name() {  # <line>
  local rest
  case "$1" in
    "- "*) ;;
    *) return 1 ;;
  esac
  rest=${1#- }
  case "$rest" in
    *[[:space:]]*) printf '%s\n' "${rest%%[[:space:]]*}" ;;
    *) return 1 ;;
  esac
}

registry_annotation() {  # <name> <line>
  local name=$1 line=$2 rest
  rest=${line#"- $name "}
  case "$rest" in
    \[*)
      case "$rest" in
        *\]*) rest=${rest#\[}; printf '%s\n' "${rest%%\]*}" ;;
        *) echo "error: malformed registry annotation for $name: missing closing ]" >&2; return 2 ;;
      esac
      ;;
    *) printf '\n' ;;
  esac
}

mode_yolo_from_annotation() {  # <name> <annotation>
  local name=$1 ann=$2 token mode=no-mistakes yolo=off mode_set=0
  for token in $ann; do
    case "$token" in
      +yolo) yolo=on ;;
      path=*) ;;
      *)
        if [ "$mode_set" -eq 0 ]; then
          mode=$token
          mode_set=1
        fi
        ;;
    esac
  done
  case "$mode" in
    no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *)
      echo "warn: unknown mode \"$mode\" for $name; defaulting to no-mistakes off" >&2
      mode=no-mistakes
      yolo=off
      ;;
  esac
  case "$yolo" in on|off) ;; *) yolo=off ;; esac
  if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
    mode=no-mistakes
  fi
  printf '%s %s\n' "$mode" "$yolo"
}

explicit_paths_from_annotation() {  # <name> <annotation>
  local name=$1 ann=$2 token path count=0
  for token in $ann; do
    case "$token" in
      path=*)
        count=$((count + 1))
        path=${token#path=}
        case "$path" in
          /*) ;;
          *) echo "error: malformed path identity for $name: path= must be an absolute path" >&2; return 2 ;;
        esac
        printf '%s\n' "$path"
        ;;
    esac
  done
  if [ "$count" -gt 1 ]; then
    echo "error: malformed path identity for $name: multiple path= tokens" >&2
    return 2
  fi
}

absolute_code_paths_from_line() {  # <line>
  local rest=$1 code
  while :; do
    case "$rest" in
      *'`'*) rest=${rest#*'`'} ;;
      *) return 0 ;;
    esac
    case "$rest" in
      *'`'*)
        code=${rest%%'`'*}
        rest=${rest#*'`'}
        ;;
      *) return 0 ;;
    esac
    case "$code" in
      /*) printf '%s\n' "$code" ;;
    esac
  done
}

paths_for_registry_line() {  # <name> <line> <annotation>
  local name=$1 line=$2 ann=$3 explicit candidate
  explicit=$(explicit_paths_from_annotation "$name" "$ann") || return 2
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return
  fi
  candidate="$PROJECTS/$name"
  normalize_path "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
  absolute_code_paths_from_line "$line"
}

if [ ! -f "$REG" ]; then
  name=$(default_name)
  echo "warn: no registry at $REG; defaulting $name to no-mistakes off" >&2
  print_result "$name" no-mistakes off
  exit 0
fi

if [ -z "$PATH_ARG" ]; then
  parsed=
  while IFS= read -r line; do
    line_name=$(registry_line_name "$line" || true)
    [ "$line_name" = "$NAME" ] || continue
    ann=$(registry_annotation "$line_name" "$line") || exit 2
    parsed=$(mode_yolo_from_annotation "$line_name" "$ann")
    break
  done < "$REG"

  if [ -z "$parsed" ]; then
    echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
    print_result "$NAME" no-mistakes off
    exit 0
  fi

  mode=${parsed%% *}
  yolo=${parsed##* }
  print_result "$NAME" "$mode" "$yolo"
  exit 0
fi

target=$(normalize_path "$PATH_ARG") || {
  echo "error: --path must be an absolute path or an existing directory: $PATH_ARG" >&2
  exit 2
}
matches=
while IFS= read -r line; do
  line_name=$(registry_line_name "$line" || true)
  [ -n "$line_name" ] || continue
  ann=$(registry_annotation "$line_name" "$line") || exit 2
  paths=$(paths_for_registry_line "$line_name" "$line" "$ann") || exit 2
  matched=0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate=$(normalize_path "$candidate") || {
      echo "error: malformed path identity for $line_name: path is not absolute: $candidate" >&2
      exit 2
    }
    if [ "$candidate" = "$target" ]; then
      matched=1
    fi
  done <<EOF
$paths
EOF
  [ "$matched" -eq 1 ] || continue
  parsed=$(mode_yolo_from_annotation "$line_name" "$ann")
  matches="${matches}${matches:+
}$line_name $parsed"
done < "$REG"

case "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" in
  0)
    name=$(default_name)
    echo "warn: no project registered for path \"$PATH_ARG\"; defaulting $name to no-mistakes off" >&2
    print_result "$name" no-mistakes off
    exit 0
    ;;
  1)
    IFS=' ' read -r match_name match_mode match_yolo <<EOF
$matches
EOF
    print_result "$match_name" "$match_mode" "$match_yolo"
    exit 0
    ;;
  *)
    echo "error: ambiguous path identity \"$PATH_ARG\" matches multiple projects:" >&2
    printf '%s\n' "$matches" | sed '/^$/d; s/^/  - /' >&2
    exit 2
    ;;
esac
