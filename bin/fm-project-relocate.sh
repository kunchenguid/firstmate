#!/usr/bin/env bash
# Relocate one captain-authorized project clone out of the active firstmate
# home's projects/ directory with a same-filesystem rename only.
#
# Usage:
#   fm-project-relocate.sh <project-name> <destination-root>
#
# <project-name> must be one plain projects/ entry name.
# <destination-root> must be an explicit absolute, ordinary, non-symlink
# directory on the same filesystem as <FM_HOME>/projects/<project-name>.
# The destination is <destination-root>/<project-name> and must not exist.
#
# This is the sole sanctioned project-relocation path after captain approval.
# It refuses before moving anything unless the source and destination root are
# ordinary directories, the source is a standalone Git clone with no linked
# worktrees, its working tree is clean, every local branch and HEAD are landed
# on origin's default branch, and no primary task metadata or registered
# secondmate lists the project. It also refuses path traversal, source-to-
# destination nesting, cross-device moves, registry ambiguity, and unsafe
# registry/state files. The project move uses `mv -T` only after those guards;
# `-T` prevents a raced destination directory from changing the operation into
# a recursive move. A registry entry is removed only after that rename succeeds.
# If registry publication fails, the helper attempts the inverse rename before
# reporting failure, preserving the source whenever the filesystem permits it.
# No recursive deletion is used.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="$FM_HOME/projects"
DATA="$FM_HOME/data"
STATE="$FM_HOME/state"

# shellcheck source=bin/fm-gate-refuse-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  sed -n '2,19{s/^# \{0,1\}//;p;}' "$0" >&2
}

die() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

fail_after_move() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

path_is_direct_child() {
  local root=$1 path=$2 tail
  case "$path" in
    "$root"/*)
      tail=${path#"$root"/}
      [ -n "$tail" ] || return 1
      case "$tail" in */*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

path_is_within_or_equal() {
  local root=$1 path=$2
  [ "$root" = "$path" ] && return 0
  case "$path" in "$root"/*) return 0 ;; esac
  return 1
}

canonical_ordinary_dir() {
  local path=$1 label=$2
  if [ -L "$path" ]; then
    printf 'REFUSED: %s must not be a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if [ ! -d "$path" ]; then
    printf 'REFUSED: %s is not a directory: %s\n' "$label" "$path" >&2
    return 1
  fi
  cd "$path" && pwd -P
}

device_for_path() {
  case "$(uname -s)" in
    Darwin) stat -f %d "$1" ;;
    *) stat -c %d "$1" ;;
  esac
}

optional_operational_dir() {
  local path=$1 label=$2
  if [ -L "$path" ]; then
    printf 'REFUSED: %s must not be a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if [ ! -e "$path" ]; then
    return 0
  fi
  canonical_ordinary_dir "$path" "$label"
}

source_is_standalone_clone() {
  local top git_dir worktrees count listed
  top=$(git -C "$SOURCE" rev-parse --show-toplevel 2>/dev/null) \
    || die "source project is not an inspectable Git repository: $SOURCE"
  top=$(canonical_ordinary_dir "$top" "source Git top-level") || exit 1
  [ "$top" = "$SOURCE" ] \
    || die "source project is not the Git top-level: $SOURCE"
  [ -d "$SOURCE/.git" ] && [ ! -L "$SOURCE/.git" ] \
    || die "source project is not a standalone Git clone: $SOURCE"
  git_dir=$(git -C "$SOURCE" rev-parse --git-dir 2>/dev/null) \
    || die "cannot inspect source Git directory: $SOURCE"
  [ "$git_dir" = .git ] \
    || die "source project has a linked Git directory: $SOURCE"
  worktrees=$(git -C "$SOURCE" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
    || die "cannot inspect linked worktrees for $SOURCE"
  count=$(printf '%s\n' "$worktrees" | awk '$1 == "worktree" { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] \
    || die "source project has $count registered worktrees; expected exactly one"
  listed=$(printf '%s\n' "$worktrees" | awk '$1 == "worktree" { sub(/^worktree /, ""); print; exit }')
  [ "$listed" = "$SOURCE" ] \
    || die "source project's registered worktree does not match its declared path"
}

source_has_clean_worktree() {
  local dirty
  dirty=$(git -C "$SOURCE" status --porcelain=v1 --untracked-files=all 2>/dev/null) \
    || die "cannot inspect working tree for $SOURCE"
  [ -z "$dirty" ] || die "source project has uncommitted or untracked changes"
}

source_has_only_landed_commits() {
  local remote_head default_branch default_ref unpushed_head unpushed_branches branches branch
  remote_head=$(git -C "$SOURCE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  case "$remote_head" in
    origin/*) default_branch=${remote_head#origin/} ;;
    *) die "cannot determine origin's default branch for $SOURCE" ;;
  esac
  default_ref="refs/remotes/origin/$default_branch"
  git -C "$SOURCE" show-ref --verify --quiet "$default_ref" \
    || die "origin's default branch is unavailable locally: origin/$default_branch"
  unpushed_head=$(git -C "$SOURCE" log --format=%H HEAD --not --remotes 2>/dev/null) \
    || die "cannot inspect HEAD for commits absent from remotes"
  unpushed_branches=$(git -C "$SOURCE" log --format=%H --branches --not --remotes 2>/dev/null) \
    || die "cannot inspect local branches for commits absent from remotes"
  if [ -n "$unpushed_head" ] || [ -n "$unpushed_branches" ]; then
    die "source project has commits absent from every remote"
  fi
  if ! git -C "$SOURCE" merge-base --is-ancestor HEAD "$default_ref"; then
    die "source HEAD is not landed on origin/$default_branch"
  fi
  branches=$(git -C "$SOURCE" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null) \
    || die "cannot inspect local branches for landed status"
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if ! git -C "$SOURCE" merge-base --is-ancestor "refs/heads/$branch" "$default_ref"; then
      die "local branch $branch is not landed on origin/$default_branch"
    fi
  done <<EOF
$branches
EOF
}

metadata_references_source() {
  local meta line recorded recorded_abs
  [ -n "${STATE_ABS:-}" ] || return 1
  local -a metas=("$STATE_ABS"/*.meta "$STATE_ABS"/.*.meta)
  for meta in "${metas[@]}"; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ -L "$meta" ]; then
      printf 'REFUSED: task metadata must not be a symlink: %s\n' "$meta" >&2
      return 2
    fi
    if [ ! -f "$meta" ]; then
      printf 'REFUSED: task metadata is not a regular file: %s\n' "$meta" >&2
      return 2
    fi
    while IFS= read -r line; do
      case "$line" in
        project=*)
          recorded=${line#project=}
          case "$recorded" in
            "$SOURCE"|"$SOURCE"/)
              printf '%s\n' "$meta"
              return 0
              ;;
          esac
          if [ -d "$recorded" ]; then
            recorded_abs=$(cd "$recorded" && pwd -P) || {
              printf 'REFUSED: cannot resolve project path in task metadata: %s\n' "$meta" >&2
              return 2
            }
            if [ "$recorded_abs" = "$SOURCE" ]; then
              printf '%s\n' "$meta"
              return 0
            fi
          fi
          ;;
      esac
    done < "$meta"
  done
  return 1
}

registered_secondmate_references_project() {
  local ref
  [ -n "${DATA_ABS:-}" ] || return 1
  [ -e "$SECONDMATES" ] || [ -L "$SECONDMATES" ] || return 1
  if [ -L "$SECONDMATES" ]; then
    printf 'REFUSED: secondmate registry must not be a symlink: %s\n' "$SECONDMATES" >&2
    return 2
  fi
  if [ ! -f "$SECONDMATES" ]; then
    printf 'REFUSED: secondmate registry is not a regular file: %s\n' "$SECONDMATES" >&2
    return 2
  fi
  ref=$(awk -v project="$NAME" '
    $1 == "-" {
      line = $0
      if (match(line, /projects:[[:space:]]*[^;)]*/)) {
        listed = substr(line, RSTART + 9, RLENGTH - 9)
        count = split(listed, entries, ",")
        for (i = 1; i <= count; i++) {
          entry = entries[i]
          sub(/^[[:space:]]+/, "", entry)
          sub(/[[:space:]]+$/, "", entry)
          if (entry == project) {
            print $2
            found = 1
            exit
          }
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$SECONDMATES") || return 1
  printf '%s\n' "$ref"
}

REGISTRY_ACTION=none
REGISTRY_TMP=
cleanup_registry_tmp() {
  [ -n "${REGISTRY_TMP:-}" ] && rm -f "$REGISTRY_TMP"
  return 0
}
trap cleanup_registry_tmp EXIT HUP INT TERM

prepare_registry_update() {
  local count
  [ -n "${DATA_ABS:-}" ] || return 0
  [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ] || return 0
  [ ! -L "$REGISTRY" ] \
    || die "project registry must not be a symlink: $REGISTRY"
  [ -f "$REGISTRY" ] \
    || die "project registry is not a regular file: $REGISTRY"
  count=$(awk -v project="$NAME" '$1 == "-" && $2 == project { count++ } END { print count + 0 }' "$REGISTRY") \
    || die "cannot inspect project registry: $REGISTRY"
  case "$count" in
    0) return 0 ;;
    1) ;;
    *) die "project registry has $count entries for $NAME; resolve the ambiguity first" ;;
  esac
  REGISTRY_TMP=$(mktemp "$DATA_ABS/.fm-project-relocate.XXXXXX") \
    || die "cannot prepare project-registry update in $DATA_ABS"
  awk -v project="$NAME" '!($1 == "-" && $2 == project) { print }' "$REGISTRY" > "$REGISTRY_TMP" \
    || die "cannot prepare project-registry update for $NAME"
  REGISTRY_ACTION=remove
}

publish_registry_update() {
  [ "$REGISTRY_ACTION" = remove ] || return 0
  mv -f "$REGISTRY_TMP" "$REGISTRY" || return 1
  REGISTRY_TMP=
}

rollback_relocation() {
  if [ -e "$SOURCE" ] || [ -L "$SOURCE" ]; then
    printf 'ERROR: registry update failed and source path was recreated; clone remains at %s\n' "$DESTINATION" >&2
    return 1
  fi
  if mv -T "$DESTINATION" "$SOURCE"; then
    return 0
  fi
  printf 'ERROR: registry update failed and inverse rename also failed; clone remains at %s\n' "$DESTINATION" >&2
  return 1
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 2 ] || { usage; exit 2; }
NAME=$1
DESTINATION_ROOT_RAW=$2
case "$NAME" in
  ''|.|..|*/*|*';'*|*'('*|*')'*|*[[:space:]]*) die "project name must be one plain projects/ entry" ;;
esac
case "$DESTINATION_ROOT_RAW" in
  /*) ;;
  *) die "destination root must be an explicit absolute path" ;;
esac

# This mutation must never be driven by a no-mistakes gate agent.
fm_refuse_if_gate_agent "$FM_ROOT"

PROJECTS_ABS=$(canonical_ordinary_dir "$PROJECTS" "source projects root") || exit 1
SOURCE="$PROJECTS_ABS/$NAME"
SOURCE=$(canonical_ordinary_dir "$SOURCE" "source project") || exit 1
path_is_direct_child "$PROJECTS_ABS" "$SOURCE" \
  || die "source project escapes the declared projects root"

DESTINATION_ROOT=$(canonical_ordinary_dir "$DESTINATION_ROOT_RAW" "destination root") || exit 1
DESTINATION="$DESTINATION_ROOT/$NAME"
path_is_direct_child "$DESTINATION_ROOT" "$DESTINATION" \
  || die "destination project escapes the declared destination root"
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  die "destination project path already exists: $DESTINATION"
fi
if path_is_within_or_equal "$SOURCE" "$DESTINATION"; then
  die "destination project path is inside the source project"
fi

SOURCE_DEVICE=$(device_for_path "$SOURCE") \
  || die "cannot determine source filesystem device"
DESTINATION_DEVICE=$(device_for_path "$DESTINATION_ROOT") \
  || die "cannot determine destination filesystem device"
[ "$SOURCE_DEVICE" = "$DESTINATION_DEVICE" ] \
  || die "source and destination are on different filesystems; rename-only relocation is impossible"

DATA_ABS=$(optional_operational_dir "$DATA" "data directory") || exit 1
STATE_ABS=$(optional_operational_dir "$STATE" "state directory") || exit 1
REGISTRY=${DATA_ABS:+$DATA_ABS/projects.md}
SECONDMATES=${DATA_ABS:+$DATA_ABS/secondmates.md}

source_is_standalone_clone
source_has_clean_worktree
source_has_only_landed_commits
task_meta=
metadata_rc=0
task_meta=$(metadata_references_source) || metadata_rc=$?
if [ "$metadata_rc" -eq 0 ]; then
  die "task metadata references this project: $task_meta"
fi
if [ "$metadata_rc" -ne 1 ]; then
  exit "$metadata_rc"
fi
secondmate=
secondmate_rc=0
secondmate=$(registered_secondmate_references_project) || secondmate_rc=$?
if [ "$secondmate_rc" -eq 0 ]; then
  die "registered secondmate $secondmate references project $NAME"
fi
if [ "$secondmate_rc" -ne 1 ]; then
  exit "$secondmate_rc"
fi
prepare_registry_update

# `-T` keeps this a rename to the exact guarded destination rather than allowing
# a late-created directory to turn it into a nested move.
if ! mv -T "$SOURCE" "$DESTINATION"; then
  fail_after_move "rename failed; source remains at $SOURCE"
fi
if ! publish_registry_update; then
  if rollback_relocation; then
    fail_after_move "project registry update failed; relocation was rolled back and source was preserved"
  fi
  fail_after_move "project registry update failed after relocation"
fi

if [ "$REGISTRY_ACTION" = remove ]; then
  printf 'relocated %s from %s to %s; removed its primary project-registry entry\n' \
    "$NAME" "$SOURCE" "$DESTINATION"
else
  printf 'relocated %s from %s to %s; no primary project-registry entry existed\n' \
    "$NAME" "$SOURCE" "$DESTINATION"
fi
