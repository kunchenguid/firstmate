#!/usr/bin/env bash
# fm-shadow.sh - publish a fail-closed, one-way snapshot of canonical Firstmate.
#
# The source must be a clean checkout on its default branch.
# The destination contains an exact copy of the source tree, including ignored
# files, project clones, operational directories, and Git metadata.
# Every run builds a complete temporary output beside the destination and
# swaps it into place only after source, scope, manifest, and fast-forward
# checks pass.
#
# A dirty, divergent, malformed, or unavailable destination is never repaired.
# The command never uses a forced Git operation, a stash, or a hard reset.
# Existing destination output is removed only after a clean replacement is
# validated and installed.
# Every Git invocation binds safe.directory to the exact checkout path for that invocation.
#
# Usage:
#   fm-shadow.sh [--source <path>] [--destination <path>]
#
# Defaults:
#   source      FM_SHADOW_SOURCE or /home/ale/firstmate
#   destination FM_SHADOW_DESTINATION or /mnt/d/Workspace/shadow
#
# The destination parent must already exist.
# The first run accepts a missing destination or an empty directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_INPUT=$(printenv FM_SHADOW_SOURCE 2>/dev/null || printf '%s\n' /home/ale/firstmate)
DEST_INPUT=$(printenv FM_SHADOW_DESTINATION 2>/dev/null || printf '%s\n' /mnt/d/Workspace/shadow)
SOURCE=
DEST=
DEST_PARENT=
LOCK_DIR=
LOCK_HELD=0
STAGE=
STAGE_MOVED=0
CONTROL_DIR=
CONTROL_STAGE=
CONTROL_STAGE_MOVED=0
CONTROL_BACKUP=
BACKUP=
DEFAULT_BRANCH=
SOURCE_COMMIT=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-shadow: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$STAGE" ] && [ -d "$STAGE" ] && [ "$STAGE_MOVED" -eq 0 ]; then
    rm -rf -- "$STAGE"
  fi
  if [ -n "$CONTROL_STAGE" ] && [ -d "$CONTROL_STAGE" ] && [ "$CONTROL_STAGE_MOVED" -eq 0 ]; then
    rm -rf -- "$CONTROL_STAGE"
  fi
  if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ]; then
    rm -f -- "$LOCK_DIR/owner"
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
  fi
}

trap 'exit 1' HUP INT TERM
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

git_at() {
  local repo=$1
  shift
  git -c "safe.directory=$repo" -C "$repo" "$@"
}

lowercase() {
  LC_ALL=C tr '[:upper:]' '[:lower:]'
}

resolve_paths() {
  [ -d "$SOURCE_INPUT" ] || die "source is not an existing directory: $SOURCE_INPUT"
  SOURCE=$(cd "$SOURCE_INPUT" && pwd -P) || die "cannot resolve source: $SOURCE_INPUT"

  local parent name
  parent=$(dirname -- "$DEST_INPUT")
  name=$(basename -- "$DEST_INPUT")
  [ -n "$name" ] && [ "$name" != . ] && [ "$name" != / ] \
    || die "destination must name a directory: $DEST_INPUT"
  [ -d "$parent" ] || die "destination parent is not an existing directory: $parent"
  DEST_PARENT=$(cd "$parent" && pwd -P) || die "cannot resolve destination parent: $parent"
  DEST="$DEST_PARENT/$name"
  CONTROL_DIR="$DEST_PARENT/.shadow-control.$name"

  [ "$SOURCE" != "$DEST" ] || die "source and destination are the same path"
  case "$DEST/" in
    "$SOURCE/"*) die "destination is inside source: $DEST" ;;
  esac
  case "$SOURCE/" in
    "$DEST/"*) die "source is inside destination: $SOURCE" ;;
  esac
  case "$(printf '%s' "$SOURCE" | lowercase)" in
    /mnt/d/rocodata|/mnt/d/rocodata/*)
      die "external /mnt/d/RocoData is outside the mirror source and is not handled by fm-shadow"
      ;;
  esac
  case "$(printf '%s' "$DEST" | lowercase)" in
    /mnt/d/rocodata|/mnt/d/rocodata/*)
      die "external /mnt/d/RocoData is protected and cannot be a mirror destination"
      ;;
  esac
  [ ! -L "$DEST" ] || die "destination must not be a symbolic link: $DEST"
  if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
    die "destination exists but is not a directory: $DEST"
  fi
  [ ! -L "$CONTROL_DIR" ] || die "replica control metadata must not be a symbolic link: $CONTROL_DIR"
  if [ -e "$CONTROL_DIR" ] && [ ! -d "$CONTROL_DIR" ]; then
    die "replica control metadata is not a directory: $CONTROL_DIR"
  fi
}

default_branch() {
  local repo=$1 ref branch
  ref=$(git_at "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$(printf '%s' "$ref" | sed 's#^origin/##')"
    return 0
  fi
  for branch in main master; do
    if git_at "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

check_source() {
  local root branch
  require_command git
  require_command python3
  root=$(git_at "$SOURCE" rev-parse --show-toplevel 2>/dev/null) \
    || die "source is not a Git worktree: $SOURCE"
  root=$(cd "$root" && pwd -P) || die "cannot resolve source Git root: $SOURCE"
  [ "$root" = "$SOURCE" ] || die "source must be the Git worktree root: $SOURCE"
  branch=$(git_at "$SOURCE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || die "source must be checked out on a named branch"
  DEFAULT_BRANCH=$(default_branch "$SOURCE") \
    || die "cannot determine source default branch from origin/HEAD, main, or master"
  [ "$branch" = "$DEFAULT_BRANCH" ] \
    || die "source branch '$branch' is not the default branch '$DEFAULT_BRANCH'"
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git_at "$SOURCE" status --porcelain=v1 --untracked-files=all)" ] \
    || die "source working tree is dirty; refusing to publish"
  SOURCE_COMMIT=$(git_at "$SOURCE" rev-parse --verify HEAD 2>/dev/null) \
    || die "cannot resolve source HEAD"
  git_at "$SOURCE" cat-file -e "$SOURCE_COMMIT^{commit}" \
    || die "source HEAD is not a commit: $SOURCE_COMMIT"
}

acquire_lock() {
  LOCK_DIR="$DEST_PARENT/.shadow.lock"
  mkdir -- "$LOCK_DIR" 2>/dev/null \
    || die "another fm-shadow execution holds the lock: $LOCK_DIR"
  LOCK_HELD=1
  {
    printf 'pid=%s\n' "$$"
    printf 'source=%s\n' "$SOURCE"
    printf 'destination=%s\n' "$DEST"
  } >"$LOCK_DIR/owner" || die "cannot record lock owner: $LOCK_DIR"
}

check_destination_git_clean() {
  local status line
  status=$(GIT_OPTIONAL_LOCKS=0 git_at "$DEST" status --porcelain=v1 --untracked-files=all) \
    || die "cannot inspect destination status"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    die "destination has changes: $line"
  done <<<"$status"
}

check_existing_destination() {
  local root head
  if [ ! -d "$DEST" ] || [ -z "$(find "$DEST" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    [ ! -e "$CONTROL_DIR" ] || die "replica control metadata exists without a complete destination: $CONTROL_DIR"
    return 0
  fi
  root=$(git_at "$DEST" rev-parse --show-toplevel 2>/dev/null) \
    || die "existing destination is not a Git worktree: $DEST"
  root=$(cd "$root" && pwd -P) || die "cannot resolve destination Git root: $DEST"
  [ "$root" = "$DEST" ] || die "destination must be the Git worktree root: $DEST"
  head=$(git_at "$DEST" rev-parse --verify HEAD 2>/dev/null) \
    || die "destination has no commit"
  git_at "$SOURCE" merge-base --is-ancestor "$head" "$SOURCE_COMMIT" \
    || die "destination commit $head diverges from source commit $SOURCE_COMMIT"
  python3 "$SCRIPT_DIR/fm-shadow.py" validate \
    --root "$DEST" --manifest "$CONTROL_DIR/manifest" --policy "$CONTROL_DIR/policy" \
    --branch "$DEFAULT_BRANCH" --commit "$head" \
    || die "destination manifest validation failed"
  check_destination_git_clean
}

build_stage() {
  local clone_head
  STAGE=$(mktemp -d "$DEST_PARENT/.shadow-stage.XXXXXX") \
    || die "cannot create staging directory beside destination"
  rmdir -- "$STAGE"
  CONTROL_STAGE=$(mktemp -d "$DEST_PARENT/.shadow-control-stage.XXXXXX") \
    || die "cannot create replica control staging directory"
  python3 "$SCRIPT_DIR/fm-shadow.py" copy --source "$SOURCE" --stage "$STAGE" \
    || die "cannot mirror source into the temporary replica"
  clone_head=$(git_at "$STAGE" rev-parse --verify HEAD 2>/dev/null) \
    || die "staged replica has no commit"
  [ "$clone_head" = "$SOURCE_COMMIT" ] \
    || die "staged commit $clone_head differs from source commit $SOURCE_COMMIT"
  [ "$(git_at "$STAGE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$DEFAULT_BRANCH" ] \
    || die "staged replica is not on default branch $DEFAULT_BRANCH"
  cat >"$CONTROL_STAGE/policy" <<EOF
shadow-policy-v1
direction=source-to-destination
source=$SOURCE
source_branch=$DEFAULT_BRANCH
source_commit=$SOURCE_COMMIT
mirror=every-path-under-source-root
destination_is_output_only=true
manual_destination_edits=refuse-next-replication
external_rocodata=outside-source-refused
EOF
  python3 "$SCRIPT_DIR/fm-shadow.py" manifest \
    --root "$STAGE" --source "$SOURCE" --branch "$DEFAULT_BRANCH" --commit "$SOURCE_COMMIT" \
    --policy "$CONTROL_STAGE/policy" --output "$CONTROL_STAGE/manifest" \
    || die "cannot write the replica manifest"
}

recheck_source() {
  local branch commit
  branch=$(git_at "$SOURCE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  commit=$(git_at "$SOURCE" rev-parse --verify HEAD 2>/dev/null || true)
  [ "$branch" = "$DEFAULT_BRANCH" ] && [ "$commit" = "$SOURCE_COMMIT" ] \
    || die "source changed while the replica was being built; no destination update was made"
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git_at "$SOURCE" status --porcelain=v1 --untracked-files=all)" ] \
    || die "source became dirty while the replica was being built; no destination update was made"
  python3 "$SCRIPT_DIR/fm-shadow.py" compare --source "$SOURCE" --replica "$STAGE" \
    || die "source tree changed while the replica was being built; no destination update was made"
}

same_output() {
  [ -f "$CONTROL_DIR/manifest" ] && [ -f "$CONTROL_DIR/policy" ] \
    && cmp -s "$CONTROL_STAGE/manifest" "$CONTROL_DIR/manifest" \
    && cmp -s "$CONTROL_STAGE/policy" "$CONTROL_DIR/policy"
}

swap_replica() {
  local failed failed_control old_backup old_control_backup

  restore_old() {
    if [ -n "$CONTROL_BACKUP" ] && [ -d "$CONTROL_BACKUP" ]; then
      mv -- "$CONTROL_BACKUP" "$CONTROL_DIR" \
        || die "replacement failed and restoring replica control metadata also failed; old metadata is at $CONTROL_BACKUP"
      CONTROL_BACKUP=
    fi
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
      mv -- "$BACKUP" "$DEST" \
        || die "replacement failed and restoring the old destination also failed; old output is at $BACKUP"
      BACKUP=
    fi
  }

  if [ -d "$DEST" ]; then
    if [ -n "$(find "$DEST" -mindepth 1 -print -quit 2>/dev/null)" ]; then
      old_backup=$(mktemp -d "$DEST_PARENT/.shadow-backup.XXXXXX") \
        || die "cannot create replacement backup"
      rmdir -- "$old_backup"
      mv -- "$DEST" "$old_backup" \
        || {
          rmdir -- "$old_backup" 2>/dev/null || true
          die "cannot move the validated destination aside; no update was made"
        }
      BACKUP=$old_backup
    else
      rmdir -- "$DEST" || die "cannot remove the empty destination directory for first replica"
    fi
  fi
  if [ -e "$CONTROL_DIR" ]; then
    old_control_backup=$(mktemp -d "$DEST_PARENT/.shadow-control-backup.XXXXXX") \
      || die "cannot create replica control backup"
    rmdir -- "$old_control_backup"
    if ! mv -- "$CONTROL_DIR" "$old_control_backup"; then
      rmdir -- "$old_control_backup" 2>/dev/null || true
      restore_old
      die "cannot move the validated replica control metadata aside; no update was made"
    fi
    CONTROL_BACKUP=$old_control_backup
  fi
  if ! mv -- "$STAGE" "$DEST"; then
    restore_old
    die "cannot install the complete staged replica; no destination update was made"
  fi
  STAGE_MOVED=1
  if ! mv -- "$CONTROL_STAGE" "$CONTROL_DIR"; then
    failed=$(mktemp -d "$DEST_PARENT/.shadow-failed.XXXXXX") \
      || die "replica control installation failed and recovery storage is unavailable"
    rmdir -- "$failed"
    mv -- "$DEST" "$failed" \
      || die "replica control installation failed; failed output is at $DEST"
    restore_old
    die "cannot install replica control metadata; failed output is at $failed after restoring the old replica"
  fi
  CONTROL_STAGE_MOVED=1
  if ! python3 "$SCRIPT_DIR/fm-shadow.py" validate \
    --root "$DEST" --manifest "$CONTROL_DIR/manifest" --policy "$CONTROL_DIR/policy" \
    --branch "$DEFAULT_BRANCH" --commit "$SOURCE_COMMIT"; then
    failed=$(mktemp -d "$DEST_PARENT/.shadow-failed.XXXXXX") || die "post-install validation failed and recovery storage is unavailable"
    rmdir -- "$failed"
    mv -- "$DEST" "$failed" \
      || die "post-install validation failed; failed output is at $DEST"
    failed_control=$(mktemp -d "$DEST_PARENT/.shadow-failed-control.XXXXXX") \
      || die "post-install validation failed and control recovery storage is unavailable"
    rmdir -- "$failed_control"
    mv -- "$CONTROL_DIR" "$failed_control" \
      || die "post-install validation failed; failed control metadata is at $CONTROL_DIR"
    restore_old
    rm -rf -- "$failed"
    rm -rf -- "$failed_control"
    die "post-install validation failed; old destination was restored"
  fi
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
    rm -rf -- "$BACKUP"
    BACKUP=
  fi
  if [ -n "$CONTROL_BACKUP" ] && [ -d "$CONTROL_BACKUP" ]; then
    rm -rf -- "$CONTROL_BACKUP"
    CONTROL_BACKUP=
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -gt 1 ] || die "--source requires a path"
      SOURCE_INPUT=$2
      shift 2
      ;;
    --source=*)
      SOURCE_INPUT=$(printf '%s' "$1" | sed 's/^--source=//')
      shift
      ;;
    --destination)
      [ "$#" -gt 1 ] || die "--destination requires a path"
      DEST_INPUT=$2
      shift 2
      ;;
    --destination=*)
      DEST_INPUT=$(printf '%s' "$1" | sed 's/^--destination=//')
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument '$1' (see --help)"
      ;;
  esac
done

resolve_paths
acquire_lock
check_source
check_existing_destination
build_stage
recheck_source
if [ -d "$DEST" ] && same_output; then
  printf 'already current: %s at %s\n' "$SOURCE_COMMIT" "$DEST"
  exit 0
fi
swap_replica
printf 'replicated: %s -> %s (%s)\n' "$SOURCE" "$DEST" "$SOURCE_COMMIT"
