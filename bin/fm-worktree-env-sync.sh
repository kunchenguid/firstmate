#!/usr/bin/env bash
# Copy a configured local environment file into an isolated task worktree.
# Usage: fm-worktree-env-sync.sh <config-dir> <project-root> <worktree-root>
#
# Reads the optional local, gitignored <config-dir>/worktree-env-sync.tsv file.
# Each non-empty, non-comment row is exactly:
#   <project-root><TAB><source-file><TAB><worktree-relative-target>
#
# project-root and source-file are absolute paths and are compared after physical
# resolution. worktree-relative-target is a relative file path below the task
# worktree. The script never prints configured paths or environment contents.
# A matching missing source, invalid mapping, non-ignored target, or copy error
# prints a warning and leaves the spawn able to continue. An absent mapping file
# is a silent no-op.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 3 ] || {
  usage >&2
  exit 2
}

config_dir=$1
project_root=$2
worktree_root=$3
mapping_file="$config_dir/worktree-env-sync.tsv"

warn() {
  printf 'warning: worktree environment synchronization: %s\n' "$1" >&2
}

physical_dir() {  # <directory>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

is_safe_target() {  # <relative-path>
  local target=$1 component
  local IFS=/
  local -a components
  case "$target" in
    ''|/*|.|..|../*|*/../*|*/..|*//*) return 1 ;;
  esac
  read -r -a components <<< "$target"
  for component in "${components[@]+"${components[@]}"}"; do
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] || return 1
  done
}

prepare_target_parent() {  # <worktree-root> <relative-target>
  local root=$1 target=$2 parent_rel current component
  local IFS=/
  local -a components
  parent_rel=${target%/*}
  [ "$parent_rel" = "$target" ] && parent_rel=
  current=$root
  read -r -a components <<< "$parent_rel"
  for component in "${components[@]+"${components[@]}"}"; do
    [ -n "$component" ] || continue
    [ ! -L "$current/$component" ] || return 1
    if [ ! -e "$current/$component" ]; then
      mkdir "$current/$component" 2>/dev/null || return 1
    fi
    [ -d "$current/$component" ] || return 1
    current="$current/$component"
  done
  printf '%s\n' "$current"
}

[ -e "$mapping_file" ] || [ -L "$mapping_file" ] || exit 0
[ -f "$mapping_file" ] && [ -r "$mapping_file" ] || {
  warn 'the local mapping file is unreadable; continuing without a copied environment file'
  exit 0
}

project_real=$(physical_dir "$project_root") || {
  warn 'the project root could not be resolved; continuing without a copied environment file'
  exit 0
}
worktree_real=$(physical_dir "$worktree_root") || {
  warn 'the task worktree could not be resolved; continuing without a copied environment file'
  exit 0
}

match_count=0
source_file=
target_rel=
tab=$(printf '\t')
while IFS="$tab" read -r mapped_project mapped_source mapped_target extra || [ -n "${mapped_project:-}${mapped_source:-}${mapped_target:-}${extra:-}" ]; do
  case "${mapped_project:-}" in
    ''|'#'*) continue ;;
  esac
  if [ -z "${mapped_source:-}" ] || [ -z "${mapped_target:-}" ] || [ -n "${extra:-}" ]; then
    warn 'the local mapping file has an invalid row; continuing without that environment file'
    continue
  fi
  mapped_project_real=$(physical_dir "$mapped_project") || continue
  [ "$mapped_project_real" = "$project_real" ] || continue
  match_count=$((match_count + 1))
  source_file=$mapped_source
  target_rel=$mapped_target
done < "$mapping_file"

case "$match_count" in
  0) exit 0 ;;
  1) ;;
  *)
    warn 'the local mapping file has multiple rows for this project; continuing without a copied environment file'
    exit 0
    ;;
esac

case "$source_file" in
  /*) ;;
  *)
    warn 'the configured source file is not an absolute path; continuing without a copied environment file'
    exit 0
    ;;
esac
is_safe_target "$target_rel" || {
  warn 'the configured worktree target is unsafe; continuing without a copied environment file'
  exit 0
}
[ -f "$source_file" ] && [ -r "$source_file" ] || {
  warn 'a local environment file is configured for this project, but its source file is missing; continuing without a copied environment file'
  exit 0
}

if git -C "$worktree_real" ls-files --error-unmatch -- "$target_rel" >/dev/null 2>&1; then
  warn 'the configured worktree target is tracked; refusing to overwrite it'
  exit 0
fi
if ! git -C "$worktree_real" check-ignore -q --no-index -- "$target_rel" 2>/dev/null; then
  warn 'the configured worktree target is not git-ignored; refusing to copy the environment file'
  exit 0
fi

target_parent=$(prepare_target_parent "$worktree_real" "$target_rel") || {
  warn 'the configured worktree target parent is unsafe; continuing without a copied environment file'
  exit 0
}
target_file="$worktree_real/$target_rel"
[ ! -L "$target_file" ] || {
  warn 'the configured worktree target is a symlink; refusing to copy the environment file'
  exit 0
}
[ ! -e "$target_file" ] || [ -f "$target_file" ] || {
  warn 'the configured worktree target is not a regular file; refusing to copy the environment file'
  exit 0
}

temp_file=
cleanup_temp_file() {
  [ -z "$temp_file" ] || rm -f -- "$temp_file" 2>/dev/null
}
trap cleanup_temp_file EXIT
trap 'cleanup_temp_file; exit 143' HUP INT TERM

old_umask=$(umask)
umask 077
temp_file=$(mktemp "$target_parent/.fm-worktree-env.XXXXXXXX" 2>/dev/null) || {
  umask "$old_umask"
  warn 'could not prepare the environment-file copy; continuing without it'
  exit 0
}
umask "$old_umask"
if ! cp "$source_file" "$temp_file" 2>/dev/null || ! mv -f "$temp_file" "$target_file" 2>/dev/null; then
  rm -f "$temp_file"
  warn 'could not copy the configured environment file; continuing without it'
  exit 0
fi
if ! git -C "$worktree_real" check-ignore -q -- "$target_rel" 2>/dev/null; then
  rm -f "$target_file"
  warn 'the copied environment file was not git-ignored; removed it'
  exit 0
fi
