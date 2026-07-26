#!/usr/bin/env bash
# Clone one remote-backed project into an existing Firstmate home, register its
# delivery posture, and initialize new no-mistakes clones.
#
# SOURCE is either an origin URL/path or a project name registered in the active
# home's data/projects.md.
# A registered name resolves its origin from the active home's existing clone and
# preserves its registry line when targeting another home.
# --home defaults to FM_HOME, then this Firstmate home, and may name any existing
# main or secondmate home.
# URL/path sources default to no-mistakes with yolo off; --mode, --description,
# and --yolo set the generated registry entry.
# Existing destination paths are always refused, including broken symlinks.
# A failed clone, initialization, or registry update removes only the new clone
# created by this invocation and never resets, forces, stashes, or discards
# preexisting work.
#
# Usage:
#   fm-project-add.sh [--home <home>] [--name <name>]
#                     [--mode <no-mistakes|direct-PR>]
#                     [--description <text>] [--yolo] <source>
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
ACTIVE_HOME_INPUT="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TARGET_HOME_INPUT=$ACTIVE_HOME_INPUT
NAME=
NAME_SET=0
MODE=
MODE_SET=0
DESCRIPTION=
DESCRIPTION_SET=0
YOLO=off
YOLO_SET=0
SOURCE=

usage() {
  cat <<'EOF'
Usage: fm-project-add.sh [--home <home>] [--name <name>]
                         [--mode <no-mistakes|direct-PR>]
                         [--description <text>] [--yolo] <source>

Clone one origin URL/path, or a project registered in the active FM_HOME, into
an existing Firstmate home.
The target defaults to the active FM_HOME and may be changed with --home.
Registered projects preserve their source registry entry.
URL/path projects default to no-mistakes, yolo off, and "cloned project".
A no-mistakes project runs `no-mistakes init` and `no-mistakes doctor` before
its registry entry is committed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || { echo "error: --home requires a value" >&2; usage >&2; exit 1; }
      TARGET_HOME_INPUT=$2
      shift 2
      ;;
    --home=*)
      TARGET_HOME_INPUT=${1#--home=}
      shift
      ;;
    --name)
      [ "$#" -ge 2 ] || { echo "error: --name requires a value" >&2; usage >&2; exit 1; }
      NAME=$2
      NAME_SET=1
      shift 2
      ;;
    --name=*)
      NAME=${1#--name=}
      NAME_SET=1
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || { echo "error: --mode requires a value" >&2; usage >&2; exit 1; }
      MODE=$2
      MODE_SET=1
      shift 2
      ;;
    --mode=*)
      MODE=${1#--mode=}
      MODE_SET=1
      shift
      ;;
    --description)
      [ "$#" -ge 2 ] || { echo "error: --description requires a value" >&2; usage >&2; exit 1; }
      DESCRIPTION=$2
      DESCRIPTION_SET=1
      shift 2
      ;;
    --description=*)
      DESCRIPTION=${1#--description=}
      DESCRIPTION_SET=1
      shift
      ;;
    --yolo)
      YOLO=on
      YOLO_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [ "$#" -eq 1 ] || { echo "error: exactly one source is required" >&2; usage >&2; exit 1; }
      SOURCE=$1
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      [ -z "$SOURCE" ] || { echo "error: exactly one source is required" >&2; usage >&2; exit 1; }
      SOURCE=$1
      shift
      ;;
  esac
done

[ -n "$SOURCE" ] || { echo "error: exactly one source is required" >&2; usage >&2; exit 1; }
case "$MODE" in
  ''|no-mistakes|direct-PR) ;;
  *) echo "error: unsupported delivery mode: $MODE" >&2; exit 1 ;;
esac
case "$DESCRIPTION" in
  *$'\n'*|*$'\r'*) echo "error: description must be one line" >&2; exit 1 ;;
esac

canonical_home() {
  local input=$1 home
  [ -d "$input" ] || { echo "error: Firstmate home does not exist: $input" >&2; return 1; }
  home=$(CDPATH='' cd -- "$input" && pwd -P) || return 1
  [ "$home" != / ] || { echo "error: Firstmate home cannot be the filesystem root" >&2; return 1; }
  [ -f "$home/AGENTS.md" ] || { echo "error: $home is not a Firstmate home (missing AGENTS.md)" >&2; return 1; }
  [ -d "$home/bin" ] || { echo "error: $home is not a Firstmate home (missing bin/)" >&2; return 1; }
  printf '%s\n' "$home"
}

path_is_inside() {
  local parent=$1 child=$2
  case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

ensure_home_directory() {
  local home=$1 name=$2 path resolved
  path="$home/$name"
  if [ -L "$path" ] && [ ! -e "$path" ]; then
    echo "error: $name is a broken symlink in Firstmate home $home" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    echo "error: $path exists and is not a directory" >&2
    return 1
  fi
  mkdir -p -- "$path"
  resolved=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
  path_is_inside "$home" "$resolved" || {
    echo "error: $name directory resolves outside Firstmate home $home" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

validate_project_name() {
  local name=$1
  case "$name" in
    ''|.|..|*[!A-Za-z0-9._-]*|/*|*/*)
      echo "error: invalid flat project name: $name" >&2
      return 1
      ;;
  esac
  case "$name" in
    [A-Za-z0-9]*) ;;
    *) echo "error: project name must start with a letter or digit: $name" >&2; return 1 ;;
  esac
}

registry_entry_count() {
  local registry=$1 name=$2
  [ -f "$registry" ] || { printf '0\n'; return 0; }
  awk -v n="$name" '$1 == "-" && $2 == n { count++ } END { print count + 0 }' "$registry"
}

registry_line_for_name() {
  local registry=$1 name=$2
  [ -f "$registry" ] || return 1
  awk -v n="$name" '$1 == "-" && $2 == n { print; exit }' "$registry"
}

project_mode_in_home() {
  local home=$1 name=$2 parsed mode yolo
  parsed=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_HOME="$home" \
    "$SCRIPT_DIR/fm-project-mode.sh" "$name") || return 1
  read -r mode yolo <<EOF
$parsed
EOF
  case "$mode" in
    no-mistakes|direct-PR) ;;
    *) echo "error: registered project $name has unsupported delivery mode: $mode" >&2; return 1 ;;
  esac
  case "$yolo" in
    on|off) ;;
    *) echo "error: registered project $name has invalid yolo posture: $yolo" >&2; return 1 ;;
  esac
  printf '%s %s\n' "$mode" "$yolo"
}

# This is the relative-origin normalization used by fm-home-seed.sh: URL and
# scp-style origins remain unchanged, while local relative origins are resolved
# from the source clone rather than from this command's caller.
normalize_joined_path() {
  local prefix=$1 tail=$2 component out old_ifs
  out=${prefix%/}
  [ -n "$out" ] || out=/
  old_ifs=$IFS
  IFS=/
  for component in $tail; do
    case "$component" in
      ''|.) ;;
      ..)
        if [ "$out" != / ]; then
          out=${out%/*}
          [ -n "$out" ] || out=/
        fi
        ;;
      *)
        if [ "$out" = / ]; then out="/$component"; else out="$out/$component"; fi
        ;;
    esac
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

canonical_path_for_check() {
  local path=$1 probe tail prefix parent base
  case "$path" in
    /*) probe=$path ;;
    *) probe="$(pwd -P)/$path" ;;
  esac
  while [ "$probe" != / ] && [ "${probe%/}" != "$probe" ]; do probe=${probe%/}; done
  if [ -e "$probe" ]; then
    if [ -d "$probe" ]; then
      CDPATH='' cd -- "$probe" && pwd -P
    else
      parent=$(dirname -- "$probe")
      base=$(basename -- "$probe")
      CDPATH='' cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base"
    fi
    return
  fi
  tail=
  while [ ! -e "$probe" ] && [ "$probe" != / ]; do
    tail="$(basename -- "$probe")${tail:+/$tail}"
    probe=$(dirname -- "$probe")
  done
  if [ -d "$probe" ]; then
    prefix=$(CDPATH='' cd -- "$probe" && pwd -P)
  elif [ -e "$probe" ]; then
    parent=$(dirname -- "$probe")
    base=$(basename -- "$probe")
    prefix=$(CDPATH='' cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base")
  else
    prefix=/
  fi
  normalize_joined_path "$prefix" "$tail"
}

normalize_origin_url() {
  local base=$1 url=$2 prefix
  case "$url" in
    file://*|*://*) printf '%s\n' "$url"; return ;;
    *:*)
      prefix=${url%%:*}
      case "$prefix" in
        */*) ;;
        *) printf '%s\n' "$url"; return ;;
      esac
      ;;
  esac
  ( CDPATH='' cd -- "$base" && canonical_path_for_check "$url" )
}

derive_name_from_source() {
  local source=$1 candidate
  candidate=${source%%\#*}
  candidate=${candidate%%\?*}
  while [ "${candidate%/}" != "$candidate" ]; do candidate=${candidate%/}; done
  candidate=${candidate##*/}
  candidate=${candidate##*:}
  candidate=${candidate%.git}
  printf '%s\n' "$candidate"
}

registry_stamp() {
  local registry=$1
  if [ -e "$registry" ]; then
    [ -f "$registry" ] || { echo "error: project registry is not a regular file: $registry" >&2; return 1; }
    printf 'present:'
    cksum < "$registry"
  else
    printf 'absent\n'
  fi
}

ACTIVE_HOME=$(canonical_home "$ACTIVE_HOME_INPUT")
TARGET_HOME=$(canonical_home "$TARGET_HOME_INPUT")
DATA=$(ensure_home_directory "$TARGET_HOME" data)
PROJECTS=$(ensure_home_directory "$TARGET_HOME" projects)
REGISTRY="$DATA/projects.md"
if [ -L "$REGISTRY" ]; then
  echo "error: project registry must not be a symlink: $REGISTRY" >&2
  exit 1
fi
if [ -e "$REGISTRY" ] && [ ! -f "$REGISTRY" ]; then
  echo "error: project registry is not a regular file: $REGISTRY" >&2
  exit 1
fi

ACTIVE_REGISTRY="$ACTIVE_HOME/data/projects.md"
REGISTERED_COUNT=$(registry_entry_count "$ACTIVE_REGISTRY" "$SOURCE")
REGISTRY_LINE=
ORIGIN=

if [ "$REGISTERED_COUNT" -gt 0 ]; then
  [ "$REGISTERED_COUNT" -eq 1 ] || { echo "error: registered project $SOURCE has duplicate entries in $ACTIVE_REGISTRY" >&2; exit 1; }
  validate_project_name "$SOURCE"
  if [ "$NAME_SET" -eq 1 ] && [ "$NAME" != "$SOURCE" ]; then
    echo "error: --name cannot rename registered project $SOURCE" >&2
    exit 1
  fi
  if [ "$MODE_SET" -eq 1 ] || [ "$DESCRIPTION_SET" -eq 1 ] || [ "$YOLO_SET" -eq 1 ]; then
    echo "error: registered project $SOURCE preserves its registry posture; omit --mode, --description, and --yolo" >&2
    exit 1
  fi
  NAME=$SOURCE
  SOURCE_PROJECTS="$ACTIVE_HOME/projects"
  [ -d "$SOURCE_PROJECTS" ] || { echo "error: active home has no projects directory: $SOURCE_PROJECTS" >&2; exit 1; }
  SOURCE_PROJECT="$SOURCE_PROJECTS/$SOURCE"
  [ -d "$SOURCE_PROJECT" ] || { echo "error: registered project $SOURCE has no clone at $SOURCE_PROJECT" >&2; exit 1; }
  git -C "$SOURCE_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "error: registered project $SOURCE is not a Git repository: $SOURCE_PROJECT" >&2
    exit 1
  }
  ORIGIN=$(git -C "$SOURCE_PROJECT" remote get-url origin 2>/dev/null || true)
  [ -n "$ORIGIN" ] || { echo "error: registered project $SOURCE has no origin remote" >&2; exit 1; }
  ORIGIN=$(normalize_origin_url "$SOURCE_PROJECT" "$ORIGIN")
  read -r MODE YOLO <<EOF
$(project_mode_in_home "$ACTIVE_HOME" "$SOURCE")
EOF
  REGISTRY_LINE=$(registry_line_for_name "$ACTIVE_REGISTRY" "$SOURCE")
else
  if [ "$NAME_SET" -eq 0 ]; then NAME=$(derive_name_from_source "$SOURCE"); fi
  validate_project_name "$NAME"
  ORIGIN=$(normalize_origin_url "$(pwd -P)" "$SOURCE")

  TARGET_ENTRY_COUNT=$(registry_entry_count "$REGISTRY" "$NAME")
  [ "$TARGET_ENTRY_COUNT" -le 1 ] || { echo "error: project $NAME has duplicate entries in $REGISTRY" >&2; exit 1; }
  if [ "$TARGET_ENTRY_COUNT" -eq 1 ] && [ "$MODE_SET" -eq 0 ] \
      && [ "$DESCRIPTION_SET" -eq 0 ] && [ "$YOLO_SET" -eq 0 ]; then
    REGISTRY_LINE=$(registry_line_for_name "$REGISTRY" "$NAME")
    read -r MODE YOLO <<EOF
$(project_mode_in_home "$TARGET_HOME" "$NAME")
EOF
  else
    [ "$MODE_SET" -eq 1 ] || MODE=no-mistakes
    [ "$DESCRIPTION_SET" -eq 1 ] || DESCRIPTION="cloned project"
    if [ "$YOLO" = on ]; then
      REGISTRY_LINE="- $NAME [$MODE +yolo] - $DESCRIPTION (added $(date +%F))"
    else
      REGISTRY_LINE="- $NAME [$MODE] - $DESCRIPTION (added $(date +%F))"
    fi
  fi
fi

validate_project_name "$NAME"
case "$MODE" in
  no-mistakes|direct-PR) ;;
  *) echo "error: unsupported delivery mode for $NAME: $MODE" >&2; exit 1 ;;
esac

DESTINATION="$PROJECTS/$NAME"
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  echo "error: refusing to clobber existing project path: $DESTINATION" >&2
  exit 1
fi

if [ "$MODE" = no-mistakes ] && ! command -v no-mistakes >/dev/null 2>&1; then
  echo "error: no-mistakes command not found; cannot initialize $NAME" >&2
  exit 1
fi

REGISTRY_STAMP=$(registry_stamp "$REGISTRY")
CREATED_CLONE=0
COMMITTED=0
REGISTRY_TMP=
rollback() {
  local rc=$?
  trap - EXIT
  if [ -n "${REGISTRY_TMP:-}" ]; then rm -f -- "$REGISTRY_TMP" 2>/dev/null || true; fi
  if [ "${CREATED_CLONE:-0}" -eq 1 ] && [ "${COMMITTED:-0}" -eq 0 ]; then
    case "$DESTINATION" in
      "$PROJECTS"/*)
        if [ "$(basename -- "$DESTINATION")" = "$NAME" ]; then rm -rf -- "$DESTINATION" 2>/dev/null || true; fi
        ;;
      *) echo "warning: refused unsafe project-add rollback target: $DESTINATION" >&2 ;;
    esac
  fi
  exit "$rc"
}
trap rollback EXIT
trap 'exit 130' HUP INT TERM

if ! mkdir -- "$DESTINATION" 2>/dev/null; then
  echo "error: refusing to clobber project path created concurrently: $DESTINATION" >&2
  exit 1
fi
CREATED_CLONE=1
if ! git clone --quiet -- "$ORIGIN" "$DESTINATION"; then
  echo "error: failed to clone $SOURCE into $DESTINATION" >&2
  exit 1
fi

if [ "$MODE" = no-mistakes ]; then
  if ! ( CDPATH='' cd -- "$DESTINATION" && no-mistakes init && no-mistakes doctor ); then
    echo "error: failed to initialize no-mistakes for $NAME at $DESTINATION" >&2
    exit 1
  fi
fi

CURRENT_REGISTRY_STAMP=$(registry_stamp "$REGISTRY")
if [ "$CURRENT_REGISTRY_STAMP" != "$REGISTRY_STAMP" ]; then
  echo "error: project registry changed while $NAME was being added; refusing to overwrite it" >&2
  exit 1
fi

REGISTRY_TMP=$(mktemp "$DATA/.fm-project-add.projects.XXXXXX")
if [ -f "$REGISTRY" ]; then
  awk -v n="$NAME" '!($1 == "-" && $2 == n) { print }' "$REGISTRY" > "$REGISTRY_TMP"
else
  : > "$REGISTRY_TMP"
fi
printf '%s\n' "$REGISTRY_LINE" >> "$REGISTRY_TMP"
mv -- "$REGISTRY_TMP" "$REGISTRY"
REGISTRY_TMP=
COMMITTED=1
trap - EXIT
trap - HUP INT TERM

printf 'project=%s\n' "$NAME"
printf 'home=%s\n' "$TARGET_HOME"
printf 'mode=%s\n' "$MODE"
printf 'yolo=%s\n' "$YOLO"
