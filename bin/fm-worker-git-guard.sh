#!/usr/bin/env bash
# Per-task Git guard copied to <tasktmp>/git-guard.<nonce>/git by bin/fm-spawn.sh.
#
# The copy is placed first on PATH before a ship or scout worker launches.
# Every ordinary `git` child therefore passes through one task-frozen guard for
# the lifetime of that worker, including Git started by a test subprocess.
# The guard refuses when Git's effective cwd, -C target, work tree, or git dir
# resolves into the project's primary checkout instead of the assigned task
# worktree.
#
# The adjacent git.conf is written by fm-spawn with exactly five
# lines: worktree, primary, real_git, task_git_dir, and primary_git_dir.
# Missing, malformed, moved, or unresolvable bindings refuse rather than running
# an unguarded Git command.
#
# `git fm-isolation-check` is the executable setup assertion emitted in every
# new ship and scout brief.
# It verifies the wrapper is still first on PATH, both configured Git roots and
# git dirs remain bound, and the assigned root remains distinct from primary.
#
# This is a seatbelt against accidental path resolution, not a security sandbox.
# An absolute Git binary or a process that replaces PATH can bypass it, so the
# generated brief forbids both.
set -u

refuse_binding() {
  printf 'fm-worker-git-guard: refusing Git because the task isolation binding %s\n' "$1" >&2
  exit 126
}

refuse_primary() {
  printf "fm-worker-git-guard: refusing Git in primary checkout '%s'; use assigned worktree '%s'\n" "$PRIMARY" "$WORKTREE" >&2
  exit 126
}

physical_dir() {
  CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P
}

target_dir() {
  local base=$1 path=$2
  case "$path" in
    '') physical_dir "$base" ;;
    /*) physical_dir "$path" ;;
    *) physical_dir "$base/$path" ;;
  esac
}

physical_path() {
  local base=$1 path=$2 candidate parent leaf parent_real
  case "$path" in
    /*) candidate=$path ;;
    *) candidate=$base/$path ;;
  esac
  if [ -d "$candidate" ]; then
    physical_dir "$candidate"
    return
  fi
  parent=${candidate%/*}
  leaf=${candidate##*/}
  [ "$parent" != "$candidate" ] || parent=.
  [ -n "$leaf" ] || return 1
  parent_real=$(physical_dir "$parent") || return 1
  printf '%s/%s\n' "${parent_real%/}" "$leaf"
}

inside_path() {
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

CONFIG=$0.conf
[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] && [ -O "$CONFIG" ] || refuse_binding "is unavailable at '$CONFIG'."
exec 3< "$CONFIG" || refuse_binding "cannot be read from '$CONFIG'."
IFS= read -r LINE1 <&3 || refuse_binding "is incomplete."
IFS= read -r LINE2 <&3 || refuse_binding "is incomplete."
IFS= read -r LINE3 <&3 || refuse_binding "is incomplete."
IFS= read -r LINE4 <&3 || refuse_binding "is incomplete."
IFS= read -r LINE5 <&3 || refuse_binding "is incomplete."
if IFS= read -r _ <&3; then
  refuse_binding "has unexpected extra data."
fi
exec 3<&-
case "$LINE1" in worktree=*) WORKTREE=${LINE1#worktree=} ;; *) refuse_binding "has no worktree." ;; esac
case "$LINE2" in primary=*) PRIMARY=${LINE2#primary=} ;; *) refuse_binding "has no primary checkout." ;; esac
case "$LINE3" in real_git=*) REAL_GIT=${LINE3#real_git=} ;; *) refuse_binding "has no real Git executable." ;; esac
case "$LINE4" in task_git_dir=*) TASK_GIT_DIR=${LINE4#task_git_dir=} ;; *) refuse_binding "has no task git dir." ;; esac
case "$LINE5" in primary_git_dir=*) PRIMARY_GIT_DIR=${LINE5#primary_git_dir=} ;; *) refuse_binding "has no primary git dir." ;; esac
[ -n "$WORKTREE" ] && [ -n "$PRIMARY" ] && [ -n "$REAL_GIT" ] \
  && [ -n "$TASK_GIT_DIR" ] && [ -n "$PRIMARY_GIT_DIR" ] \
  || refuse_binding "contains an empty value."
case "$REAL_GIT" in /*) : ;; *) refuse_binding "contains a non-absolute real Git path." ;; esac
[ -x "$REAL_GIT" ] || refuse_binding "points to an unavailable real Git executable."
[ ! "$REAL_GIT" -ef "$0" ] || refuse_binding "points back to the guard instead of Git."

WORKTREE_REAL=$(physical_dir "$WORKTREE") || refuse_binding "worktree cannot be resolved."
PRIMARY_REAL=$(physical_dir "$PRIMARY") || refuse_binding "primary checkout cannot be resolved."
TASK_GIT_DIR_REAL=$(physical_dir "$TASK_GIT_DIR") || refuse_binding "task git dir cannot be resolved."
PRIMARY_GIT_DIR_REAL=$(physical_dir "$PRIMARY_GIT_DIR") || refuse_binding "primary git dir cannot be resolved."
[ "$WORKTREE_REAL" = "$WORKTREE" ] || refuse_binding "worktree path has moved."
[ "$PRIMARY_REAL" = "$PRIMARY" ] || refuse_binding "primary checkout path has moved."
[ "$TASK_GIT_DIR_REAL" = "$TASK_GIT_DIR" ] || refuse_binding "task git dir path has moved."
[ "$PRIMARY_GIT_DIR_REAL" = "$PRIMARY_GIT_DIR" ] || refuse_binding "primary git dir path has moved."
[ "$WORKTREE" != "$PRIMARY" ] || refuse_binding "collapses the task onto the primary checkout."
[ "$TASK_GIT_DIR" != "$PRIMARY_GIT_DIR" ] || refuse_binding "does not identify a distinct Git root."

self_check() {
  local path_git current task_top primary_top
  path_git=$(command -v git 2>/dev/null || true)
  [ "$path_git" = "$0" ] || refuse_binding "is no longer first on PATH."
  current=$(pwd -P 2>/dev/null) || refuse_binding "cannot resolve the current directory."
  [ "$current" = "$WORKTREE" ] || refuse_binding "setup assertion is not running from the assigned worktree."
  task_top=$("$REAL_GIT" -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) \
    || refuse_binding "worktree is no longer a Git worktree."
  primary_top=$("$REAL_GIT" -C "$PRIMARY" rev-parse --show-toplevel 2>/dev/null) \
    || refuse_binding "primary checkout is no longer a Git checkout."
  task_top=$(physical_dir "$task_top") || refuse_binding "worktree top level cannot be resolved."
  primary_top=$(physical_dir "$primary_top") || refuse_binding "primary top level cannot be resolved."
  [ "$task_top" = "$WORKTREE" ] || refuse_binding "worktree top level changed."
  [ "$primary_top" = "$PRIMARY" ] || refuse_binding "primary top level changed."
  [ "$("$REAL_GIT" -C "$WORKTREE" rev-parse --absolute-git-dir 2>/dev/null)" = "$TASK_GIT_DIR" ] \
    || refuse_binding "task git dir changed."
  [ "$("$REAL_GIT" -C "$PRIMARY" rev-parse --absolute-git-dir 2>/dev/null)" = "$PRIMARY_GIT_DIR" ] \
    || refuse_binding "primary git dir changed."
  printf "isolation guard active: worktree='%s' primary='%s'\n" "$WORKTREE" "$PRIMARY"
}

if [ "$#" -eq 1 ] && [ "$1" = fm-isolation-check ]; then
  self_check
  exit 0
fi

CURRENT=$(pwd -P 2>/dev/null) || refuse_binding "cannot resolve the current directory."
inside_path "$CURRENT" "$PRIMARY" && refuse_primary

TARGET=$CURRENT
GIT_DIR_VALUE=${GIT_DIR:-}
WORK_TREE_VALUE=${GIT_WORK_TREE:-}
ARGS=("$@")
INDEX=0
while [ "$INDEX" -lt "${#ARGS[@]}" ]; do
  ARG=${ARGS[$INDEX]}
  case "$ARG" in
    -C)
      INDEX=$((INDEX + 1))
      [ "$INDEX" -lt "${#ARGS[@]}" ] || refuse_binding "cannot classify a missing -C value."
      TARGET=$(target_dir "$TARGET" "${ARGS[$INDEX]}") \
        || refuse_binding "cannot resolve Git's -C target."
      ;;
    -C?*)
      TARGET=$(target_dir "$TARGET" "${ARG#-C}") \
        || refuse_binding "cannot resolve Git's -C target."
      ;;
    --git-dir)
      INDEX=$((INDEX + 1))
      [ "$INDEX" -lt "${#ARGS[@]}" ] || refuse_binding "cannot classify a missing --git-dir value."
      GIT_DIR_VALUE=${ARGS[$INDEX]}
      ;;
    --git-dir=*) GIT_DIR_VALUE=${ARG#--git-dir=} ;;
    --work-tree)
      INDEX=$((INDEX + 1))
      [ "$INDEX" -lt "${#ARGS[@]}" ] || refuse_binding "cannot classify a missing --work-tree value."
      WORK_TREE_VALUE=${ARGS[$INDEX]}
      ;;
    --work-tree=*) WORK_TREE_VALUE=${ARG#--work-tree=} ;;
    -c|--config-env|--namespace|--super-prefix)
      INDEX=$((INDEX + 1))
      [ "$INDEX" -lt "${#ARGS[@]}" ] || refuse_binding "cannot classify a missing global option value."
      ;;
    --) break ;;
    -*) ;;
    *) break ;;
  esac
  INDEX=$((INDEX + 1))
done

inside_path "$TARGET" "$PRIMARY" && refuse_primary
if [ -n "$WORK_TREE_VALUE" ]; then
  WORK_TREE_TARGET=$(physical_path "$TARGET" "$WORK_TREE_VALUE") \
    || refuse_binding "cannot resolve Git's work-tree target."
  inside_path "$WORK_TREE_TARGET" "$PRIMARY" && refuse_primary
fi
if [ -n "$GIT_DIR_VALUE" ]; then
  GIT_DIR_TARGET=$(physical_path "$TARGET" "$GIT_DIR_VALUE") \
    || refuse_binding "cannot resolve Git's git-dir target."
  if inside_path "$GIT_DIR_TARGET" "$PRIMARY" && [ "$GIT_DIR_TARGET" != "$TASK_GIT_DIR" ]; then
    refuse_primary
  fi
fi
if [ -n "${GIT_COMMON_DIR:-}" ]; then
  COMMON_DIR_TARGET=$(physical_path "$TARGET" "$GIT_COMMON_DIR") \
    || refuse_binding "cannot resolve Git's common-dir target."
  if inside_path "$COMMON_DIR_TARGET" "$PRIMARY" \
      && { [ "$COMMON_DIR_TARGET" != "$PRIMARY_GIT_DIR" ] || ! inside_path "$TARGET" "$WORKTREE"; }; then
    refuse_primary
  fi
fi

exec "$REAL_GIT" "$@"
