# shellcheck shell=bash
# Shared local and remote default-branch resolution.

_FM_DEFAULT_BRANCH_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_DEFAULT_BRANCH_LIB_DIR/fm-timeout-lib.sh"

fm_local_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    branch=${ref#origin/}
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_remote_default_branch() {
  local dir=$1 ref remote_url timeout=5
  remote_url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    fm_local_default_branch "$dir"
    return
  fi
  ref=$(fm_run_timed "$timeout" git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  [ -n "$ref" ] || return 1
  printf '%s\n' "$ref"
}

fm_local_only_default_branch() {
  local dir=$1 branch
  branch=$(fm_remote_default_branch "$dir" 2>/dev/null || true)
  if [ -n "$branch" ] && git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "$branch"
    return 0
  fi
  fm_local_default_branch "$dir"
}
