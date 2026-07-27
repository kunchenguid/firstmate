#!/usr/bin/env bash
# shellcheck shell=bash
# Strip embedded userinfo credentials from git remote URLs in a repository
# (and optionally its worktrees/submodules when callers pass those paths).
#
# Usage: . bin/fm-git-remote-sanitize-lib.sh
#
# Public:
#   fm_git_remote_url_strip_userinfo <url> -> stdout rewritten URL
#     Leaves scp-like and non-http(s) URLs untouched. For http(s)://user:pass@host
#     and http(s)://user@host, drops the userinfo and keeps scheme://host/path.
#   fm_git_remote_sanitize_repo <repo-dir>
#     For every remote in <repo-dir>, if its URL has userinfo, rewrite it in
#     place via `git remote set-url`. Prints one line per change to stdout:
#       sanitized remote <name>
#     Never prints the secret or the full pre-rewrite URL. Exit 0 always for
#     missing/non-git dirs (callers treat as best-effort hygiene).
#   fm_git_remote_sanitize_home_projects [<projects-dir>]
#     Walk <projects-dir>/* (default $FM_HOME/projects or $FM_PROJECTS_OVERRIDE)
#     and sanitize each clone. Intended for fleet-sync and one-shot repair.
#
# Safety: never logs passwords. set-url only runs when the stripped form differs.

fm_git_remote_url_strip_userinfo() {
  local url=$1
  case "$url" in
    http://*@*|https://*@*)
      # Drop userinfo between scheme:// and the first remaining host slash-or-end.
      # Handles user:pass@host and user@host; leaves path/query intact.
      printf '%s\n' "$url" | sed -E 's#^(https?://)[^/@]+@#\1#'
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

fm_git_remote_has_userinfo() {
  local url=$1
  case "$url" in
    http://*@*|https://*@*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_git_remote_sanitize_repo() {
  local repo=$1
  local name url cleaned remote_list

  [ -n "$repo" ] || return 0
  [ -d "$repo" ] || return 0
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  remote_list=$(git -C "$repo" remote 2>/dev/null || true)
  [ -n "$remote_list" ] || return 0

  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    url=$(git -C "$repo" remote get-url "$name" 2>/dev/null || true)
    [ -n "$url" ] || continue
    fm_git_remote_has_userinfo "$url" || continue
    cleaned=$(fm_git_remote_url_strip_userinfo "$url")
    [ -n "$cleaned" ] || continue
    [ "$cleaned" != "$url" ] || continue
    if git -C "$repo" remote set-url "$name" "$cleaned" 2>/dev/null; then
      # Callers prefix with their own project label. Never print the secret URL.
      printf 'sanitized remote %s\n' "$name"
    fi
  done <<EOF
$remote_list
EOF
}

fm_git_remote_sanitize_home_projects() {
  local projects=${1:-}
  local proj

  if [ -z "$projects" ]; then
    projects="${FM_PROJECTS_OVERRIDE:-${FM_HOME:-.}/projects}"
  fi
  [ -d "$projects" ] || return 0

  for proj in "$projects"/*; do
    [ -d "$proj" ] || continue
    fm_git_remote_sanitize_repo "$proj"
  done
}
