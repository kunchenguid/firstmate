# shellcheck shell=bash
# Shared local and remote default-branch resolution.

fm_local_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
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
  local dir=$1 ref remote_url
  remote_url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$remote_url" ]; then
    fm_local_default_branch "$dir"
    return
  fi
  ref=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  [ -n "$ref" ] || return 1
  printf '%s\n' "$ref"
}
