#!/usr/bin/env bash
# Decide whether this firstmate instance runs as a DOWNSTREAM user of the shared
# firstmate template (someone else's tool, cloned to run firstmate) or as the
# tool's OWNER/maintainer, and gate firstmate self-changes accordingly.
#
# The firstmate repo is a public template. A downstream user clones it and runs
# it; its `origin` points at the upstream template the user does NOT own. Left
# unchecked, firstmate-on-itself ship tasks (and the tool's own self-ship flow)
# open PRs against that upstream by accident. The rule this script encodes: a
# downstream instance's own changes ship LOCAL-ONLY by default and never
# auto-push or auto-PR to origin; contributing upstream is a deliberate,
# explicit opt-in (FM_CONTRIBUTE=1).
#
# Detection is entirely from live git/gh identity, so nothing user-specific is
# baked in and it is correct for every clone:
#   - origin's GitHub owner (parsed from `git remote get-url origin`)
#   - the authenticated GitHub login (`gh api user`, else `gh auth status`)
#   - owner == login (case-insensitive) -> OWNER; a fork the user owns has
#     origin owner == login, so it resolves to OWNER too.
#   - otherwise, or when either identity cannot be resolved -> DOWNSTREAM, the
#     safe default that prevents accidental writes to a template the user does
#     not own.
#
# Dual-mode: source it for the functions (fm_downstream_status,
# fm_block_firstmate_upstream), or execute it as a standalone check.
#
# Standalone usage: fm-downstream.sh [<repo-root>]   (default: FM_ROOT)
#   Prints `owner` (exit 0) or `downstream` (exit 1).

FM_DOWNSTREAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tangle-lib.sh
. "$FM_DOWNSTREAM_LIB_DIR/fm-tangle-lib.sh"

# Parse the GitHub owner (org/user) from a remote URL of any common form
# (https://, git@host:, ssh://, git://). Echoes the owner; returns 1 if the URL
# is not a github.com remote.
fm_github_owner_from_url() {
  local url=$1 rest
  case "$url" in
    *github.com[:/]*) : ;;
    *) return 1 ;;
  esac
  rest=${url#*github.com}
  rest=${rest#:}
  rest=${rest#/}
  rest=${rest%%/*}
  [ -n "$rest" ] || return 1
  printf '%s\n' "$rest"
}

# Echo origin's GitHub owner for the repo at <root> (default FM_ROOT); returns 1
# if origin is missing or not a github.com remote.
fm_origin_owner() {
  local root=${1:-${FM_ROOT:-.}} url
  url=$(git -C "$root" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  fm_github_owner_from_url "$url"
}

# Echo the authenticated GitHub login, or return 1 if it cannot be resolved.
# Prefers `gh api user` (authoritative), then parses `gh auth status`, then
# tries the gh-axi wrapper. Never hardcodes any name.
fm_gh_login() {
  local login
  if command -v gh >/dev/null 2>&1; then
    if login=$(gh api user --jq .login 2>/dev/null) && [ -n "$login" ]; then
      printf '%s\n' "$login"
      return 0
    fi
    if login=$(gh auth status 2>&1 | sed -n -E 's/.*[Ll]ogged in to [^ ]+ (as|account) ([A-Za-z0-9][A-Za-z0-9-]*).*/\2/p' | head -1) && [ -n "$login" ]; then
      printf '%s\n' "$login"
      return 0
    fi
  fi
  if command -v gh-axi >/dev/null 2>&1; then
    if login=$(gh-axi api user --jq .login 2>/dev/null) && [ -n "$login" ]; then
      printf '%s\n' "$login"
      return 0
    fi
  fi
  return 1
}

# Echo "owner" (return 0) or "downstream" (return 1) for the repo at <root>
# (default FM_ROOT). Unresolvable identity degrades to downstream.
fm_downstream_status() {
  local root=${1:-${FM_ROOT:-.}} owner login
  owner=$(fm_origin_owner "$root" 2>/dev/null || true)
  login=$(fm_gh_login 2>/dev/null || true)
  if [ -z "$owner" ] || [ -z "$login" ]; then
    echo downstream
    return 1
  fi
  if [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" ]; then
    echo owner
    return 0
  fi
  echo downstream
  return 1
}

# Backstop for firstmate-controlled push/PR seams. Given a task's
# state/<id>.meta, refuse the operation when the task's project is the firstmate
# repo itself AND this is a downstream instance AND the caller has not opted into
# upstream contribution (FM_CONTRIBUTE=1). A no-op for every non-firstmate task,
# for owner instances, and when FM_CONTRIBUTE=1.
#   Usage: fm_block_firstmate_upstream <meta-file> <what>   (returns 1 to block)
fm_block_firstmate_upstream() {
  local meta=$1 what=${2:-push/PR} proj
  [ -f "$meta" ] || return 0
  proj=$(grep '^project=' "$meta" | head -1 | cut -d= -f2- || true)
  [ -n "$proj" ] || return 0
  fm_is_firstmate_repo "$proj" || return 0
  [ "${FM_CONTRIBUTE:-}" = 1 ] && return 0
  fm_downstream_status "$proj" >/dev/null 2>&1 && return 0
  cat >&2 <<EOF
error: refusing to $what for a firstmate self-change on a downstream instance.
  This firstmate runs from a clone of the shared template it does not own, so its
  own changes ship LOCAL-ONLY by default and must never auto-PR to the upstream
  template. To deliberately contribute this change upstream, re-run with
  FM_CONTRIBUTE=1 (push to your own fork / open the PR yourself).
EOF
  return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_DOWNSTREAM_LIB_DIR/.." && pwd)}"
  root="${1:-$FM_ROOT}"
  status=$(fm_downstream_status "$root")
  rc=$?
  printf '%s\n' "$status"
  exit "$rc"
fi
