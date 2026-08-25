#!/usr/bin/env bash
# Resolve a project's registered delivery posture and path from data/projects.md.
# The default output remains two words: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --path accepts one registered project identifier and prints its resolved path.
# --list-paths prints every registered identifier and resolved path as TSV.
# --entry prints the validated registry entry for one identifier.
# --child-entry prints that entry with a child-home-local projects/<id> path.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones and enumerate
# registered paths), bin/fm-home-seed.sh (resolve source clones, refuse local-only
# seeding, and run no-mistakes init), bin/fm-remote-home-seed.sh (resolve source
# clones), bin/fm-remote-home-provision.sh (publish child-local paths), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                         -> no-mistakes off
#   - <name> [<mode>] - <desc> (added <date>)                 -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)           -> <mode> on
#   - <name> [<mode> +yolo] - <desc> (added <date>) [path=<path>]
#                                                               -> <mode> on
#
# The path field is optional for compatibility. Without it, the resolved path is
# "$FM_HOME/projects/<name>" or "$FM_PROJECTS_OVERRIDE/<name>" when that override
# is active. An absolute path is used as written, a path beginning with "projects/"
# is relative to this firstmate home, "~/..." is relative to $HOME, and any other
# relative path is under "$HOME/dpe". Path values are one whitespace-free path
# without registry delimiters, empty components, or traversal components.
# --path never accepts a path and never searches the filesystem for an identifier.
# --list-paths is the only bulk operation and exposes the resolved pairs to callers.
# --entry and --child-entry keep registry serialization inside this format owner.
# Every registry entry is validated before any result is returned, including
# duplicate identifiers and two identifiers resolving to the same clone.
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
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown project in the posture operation falls back to "no-mistakes off" and
# warns to stderr for compatibility. An unknown project in --path is an error,
# because an unregistered clone has no path that this interface may infer.
# A malformed registry entry or declared path is always an error.
# Usage: fm-project-mode.sh [--raw] <project-id>
#        fm-project-mode.sh --path <project-id>
#        fm-project-mode.sh --list-paths
#        fm-project-mode.sh --entry <project-id>
#        fm-project-mode.sh --child-entry <project-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
OP=mode
NAME=

usage() {
  echo "usage: fm-project-mode.sh [--raw] <project-id>" >&2
  echo "       fm-project-mode.sh --path <project-id>" >&2
  echo "       fm-project-mode.sh --list-paths" >&2
  echo "       fm-project-mode.sh --entry <project-id>" >&2
  echo "       fm-project-mode.sh --child-entry <project-id>" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw)
      [ "$OP" = mode ] && [ "$RAW" -eq 0 ] && [ -z "$NAME" ] || { usage; exit 2; }
      RAW=1
      ;;
    --path)
      [ "$OP" = mode ] && [ -z "$NAME" ] || { usage; exit 2; }
      OP=path
      ;;
    --list-paths|--paths)
      [ "$OP" = mode ] && [ -z "$NAME" ] || { usage; exit 2; }
      OP=list
      ;;
    --entry)
      [ "$OP" = mode ] && [ -z "$NAME" ] || { usage; exit 2; }
      OP=entry
      ;;
    --child-entry)
      [ "$OP" = mode ] && [ -z "$NAME" ] || { usage; exit 2; }
      OP='child-entry'
      ;;
    --)
      shift
      [ "$#" -eq 1 ] || { usage; exit 2; }
      if { [ "$OP" = mode ] || [ "$OP" = path ] || [ "$OP" = entry ] || [ "$OP" = child-entry ]; } \
        && [ -z "$NAME" ]; then
        :
      else
        usage
        exit 2
      fi
      NAME=$1
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if { [ "$OP" = mode ] || [ "$OP" = path ] || [ "$OP" = entry ] || [ "$OP" = child-entry ]; } && [ -z "$NAME" ]; then
        NAME=$1
      else
        usage
        exit 2
      fi
      ;;
  esac
  shift
done

if [ "$OP" = list ]; then
  [ -z "$NAME" ] && [ "$RAW" -eq 0 ] || { usage; exit 2; }
elif [ "$OP" = path ] || [ "$OP" = entry ] || [ "$OP" = child-entry ]; then
  [ "$RAW" -eq 0 ] && [ -n "$NAME" ] && [ "$#" -eq 0 ] || { usage; exit 2; }
else
  [ -n "$NAME" ] || { usage; exit 2; }
fi

valid_project_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

if [ "$OP" != list ]; then
  valid_project_id "$NAME" || {
    echo "error: project identifier must contain only letters, numbers, '.', '_' and '-' (got '$NAME')" >&2
    exit 2
  }
fi

fallback_path() {
  printf '%s/%s\n' "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}" "$1"
}

registry_records() {
  awk '
    function invalid(reason) {
      printf "error: malformed project registry entry at line %d: %s\n", NR, reason > "/dev/stderr"
      exit 2
    }
    {
      line=$0
      if (line ~ /^[[:space:]]*$/) next
      if (line !~ /^- /) invalid("expected a project entry")

      path_present=0
      path=""
      if (index(line, "[path=") > 0) {
        if (line !~ /[[:space:]]\[path=[^]]+\][[:space:]]*$/) {
          invalid("path must be a final [path=<path>] field")
        }
        suffix=line
        sub(/^.*[[:space:]]\[path=/, "", suffix)
        sub(/\][[:space:]]*$/, "", suffix)
        path=suffix
        path_present=1
        sub(/[[:space:]]\[path=[^]]+\][[:space:]]*$/, "", line)
      } else if (index(line, "[path") > 0 || index(line, "path=") > 0 || index(line, "(path:") > 0) {
        invalid("path must be a final [path=<path>] field")
      }

      rest=substr(line, 3)
      id=rest
      sub(/[[:space:]].*$/, "", id)
      if (id !~ /^[A-Za-z0-9._-]+$/ || id == "." || id == "..") {
        invalid("project identifier is invalid")
      }
      tail=substr(rest, length(id)+1)
      mode="no-mistakes"
      yolo="off"
      if (substr(tail, 1, 2) == " [") {
        close_pos=index(tail, "]")
        if (close_pos == 0) invalid("delivery posture bracket is not closed")
        bracket=substr(tail, 3, close_pos-3)
        tail=substr(tail, close_pos+1)
        token_count=split(bracket, tokens, /[[:space:]]+/)
        posture_count=0
        for (i=1; i<=token_count; i++) {
          token=tokens[i]
          if (token == "") continue
          if (token == "+yolo") {
            if (yolo == "on") invalid("+yolo is repeated")
            yolo="on"
          } else {
            posture_count++
            if (posture_count > 1) invalid("delivery posture contains multiple modes")
            mode=token
          }
        }
        if (posture_count == 0 && yolo == "off") invalid("delivery posture is empty")
      }
      if (substr(tail, 1, 3) != " - ") invalid("expected a separator before the description")
      description=substr(tail, 4)
      if (description !~ /.+[[:space:]]\(added[[:space:]]+[^)]*\)$/) {
        invalid("entry must end with (added <date>)")
      }
      print id "\t" mode "\t" yolo "\t" path_present "\t" path
    }
  ' "$REG"
}

validate_declared_path() {
  local project=$1 path=$2
  case "$path" in
    ''|*[[:space:]]*|*$'\n'*|*$'\r'*|*';'*|*'('*|*')'*|*'['*|*']'*|*'|'*|*'='*|*'//'*|*/)
      echo "error: project \"$project\" has invalid path \"$path\"" >&2
      return 1
      ;;
  esac
  case "/$path/" in
    */../*|*/./*)
      echo "error: project \"$project\" has invalid path \"$path\"" >&2
      return 1
      ;;
  esac
  case "$path" in
    projects/|\~[!/]*)
      echo "error: project \"$project\" has invalid path \"$path\"" >&2
      return 1
      ;;
    projects/*|/*|~|\~/*)
      ;;
    *)
      ;;
  esac
}

resolve_declared_path() {
  local path=$1
  case "$path" in
    projects/*)
      printf '%s/%s\n' "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}" "${path#projects/}"
      ;;
    /*)
      printf '%s\n' "$path"
      ;;
    '~')
      printf '%s\n' "${HOME:?HOME must be set to resolve project paths}"
      ;;
    \~/*)
      printf '%s/%s\n' "${HOME:?HOME must be set to resolve project paths}" "${path#\~/}"
      ;;
    *)
      printf '%s/dpe/%s\n' "${HOME:?HOME must be set to resolve project paths}" "$path"
      ;;
  esac
}

path_key() {
  local path=$1 component out old_ifs git_root
  if [ -d "$path" ]; then
    git_root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$git_root" ]; then
      (cd "$git_root" && pwd -P)
      return
    fi
    (cd "$path" && pwd -P)
    return
  fi
  case "$path" in
    /*) out=/; path=${path#/} ;;
    *) out=$PWD ;;
  esac
  old_ifs=$IFS
  IFS=/
  for component in $path; do
    case "$component" in
      ''|.) ;;
      ..)
        [ "$out" = / ] || {
          out=${out%/*}
          [ -n "$out" ] || out=/
        }
        ;;
      *)
        if [ "$out" = / ]; then out="/$component"; else out="$out/$component"; fi
        ;;
    esac
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

registry_entry() {
  local project=$1 child=${2:-0}
  awk -v n="$project" -v child="$child" '
    $1 == "-" && $2 == n {
      line=$0
      if (child == 1) {
        sub(/[[:space:]]\[path=[^]]+\][[:space:]]*$/, "", line)
        printf "%s [path=projects/%s]\n", line, n
      } else {
        print line
      }
      exit
    }
  ' "$REG"
}

declare -a PROJECT_IDS=()
declare -a PROJECT_MODES=()
declare -a PROJECT_YOLOS=()
declare -a PROJECT_PATHS=()
declare -A PROJECT_INDEX=()
declare -A PROJECT_PATH_OWNERS=()

load_registry() {
  local records id mode yolo path_present declared path key index
  [ -f "$REG" ] || return 0
  records=$(registry_records) || return 1
  while IFS=$'\t' read -r id mode yolo path_present declared; do
    [ -n "$id" ] || continue
    if [[ ${PROJECT_INDEX[$id]+present} ]]; then
      echo "error: project registry contains duplicate identifier '$id'" >&2
      return 1
    fi
    if [ "$path_present" = 1 ]; then
      validate_declared_path "$id" "$declared" || return 1
      path=$(resolve_declared_path "$declared")
    else
      path=$(fallback_path "$id")
    fi
    key=$(path_key "$path")
    if [[ ${PROJECT_PATH_OWNERS[$key]+present} ]]; then
      echo "error: projects '${PROJECT_PATH_OWNERS[$key]}' and '$id' resolve to the same clone '$key'" >&2
      return 1
    fi
    index=${#PROJECT_IDS[@]}
    PROJECT_INDEX[$id]=$index
    PROJECT_PATH_OWNERS[$key]=$id
    PROJECT_IDS+=("$id")
    PROJECT_MODES+=("$mode")
    PROJECT_YOLOS+=("$yolo")
    PROJECT_PATHS+=("$path")
  done <<< "$records"
}

load_registry || exit 1

if [ "$OP" = list ]; then
  for index in "${!PROJECT_IDS[@]}"; do
    printf '%s\t%s\n' "${PROJECT_IDS[$index]}" "${PROJECT_PATHS[$index]}"
  done
  exit 0
fi

if [[ ${PROJECT_INDEX[$NAME]+present} ]]; then
  index=${PROJECT_INDEX[$NAME]}
else
  if [ "$OP" = path ] || [ "$OP" = entry ] || [ "$OP" = child-entry ]; then
    echo "error: project '$NAME' is not registered; no path can be inferred" >&2
    exit 1
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

if [ "$OP" = path ]; then
  printf '%s\n' "${PROJECT_PATHS[$index]}"
  exit 0
fi

if [ "$OP" = entry ]; then
  registry_entry "$NAME"
  exit 0
fi

if [ "$OP" = child-entry ]; then
  registry_entry "$NAME" 1
  exit 0
fi

mode=${PROJECT_MODES[$index]}
yolo=${PROJECT_YOLOS[$index]}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *)
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2
    mode=no-mistakes
    yolo=off
    ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
