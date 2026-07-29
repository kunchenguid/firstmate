#!/usr/bin/env bash
# fm-pr-base-lib.sh - resolve the repository and default branch a checkout is
# configured to open pull requests against, and detect branches cut from a
# different repository's default branch.
#
# Sourced by bin/fm-pr-base.sh (the convergence entrypoint) and
# bin/fm-pr-check.sh (the wrong-base backstop). It reads git configuration only
# and never writes.
#
# THE PROBLEM THIS ENCODES
# A fleet that ships to its own fork keeps two remotes: the fork it merges into
# and the upstream it was forked from. `gh repo set-default` records which one
# is the pull-request base, but that record lives in ONE checkout's git config.
# Every tool that builds a second checkout - treehouse's worktree pool, the
# no-mistakes pipeline's gate worktree - resolves "the repository" and "the
# default branch" from `origin` alone and never sees that record. When `origin`
# is the upstream, those tools silently target the upstream: pull requests open
# against it, and branches are cut from its default branch.
#
# The base repository is therefore derived here from configuration - never from
# a hardcoded owner - so every fleet resolves its own fork.
#
# Public functions:
#   fm_pr_base_url_identity <url>          -> FM_PR_BASE_URL_HOST/_PATH
#   fm_pr_base_resolve <dir>               -> FM_PR_BASE_HOST/_PATH/_REMOTE/_SOURCE
#   fm_pr_base_identity_equal <h1> <p1> <h2> <p2>
#   fm_pr_base_remote_for_identity <dir> <host> <path>
#   fm_pr_base_default_branch <dir> <remote>
#   fm_pr_base_foreign_commits <dir> <base-remote> <base-branch> <rev>

# Guard against double-sourcing: bin/fm-pr-check.sh sources both this library
# and fm-pr-lib.sh, and a caller may already have sourced one of them.
if [ -n "${FM_PR_BASE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PR_BASE_LIB_SOURCED=1

FM_PR_BASE_URL_HOST=
FM_PR_BASE_URL_PATH=
FM_PR_BASE_HOST=
FM_PR_BASE_PATH=
FM_PR_BASE_REMOTE=
FM_PR_BASE_SOURCE=
FM_PR_BASE_FOREIGN_REMOTE=
FM_PR_BASE_FOREIGN_COUNT=
FM_PR_BASE_FOREIGN_IDENTITY=

# Normalize any git remote URL to the forge identity "<host>" + "<owner>/<repo>"
# so two spellings of the same repository compare equal. Accepts the three forms
# git itself accepts for a network remote: scheme URLs (https/ssh/git), scp-like
# "[user@]host:path", and scheme URLs carrying userinfo or a port. A local path
# remote - the no-mistakes gate's own file remote, for example - has no forge
# identity and is refused, which is what keeps it out of every comparison below.
fm_pr_base_url_identity() {
  local url=${1-} rest host path
  local LC_ALL=C
  FM_PR_BASE_URL_HOST=
  FM_PR_BASE_URL_PATH=
  [ -n "$url" ] || return 1
  case "$url" in
    /*|./*|../*|file://*) return 1 ;;
    *://*) rest=${url#*://} ;;
    *:*/*)
      # scp-like [user@]host:owner/repo - rewrite the single ":" separator to
      # "/" so the scheme and scp-like forms share one parser below.
      rest=${url%%:*}/${url#*:}
      ;;
    *) return 1 ;;
  esac
  rest=${rest#*@}
  host=${rest%%/*}
  path=${rest#*/}
  [ "$host" != "$rest" ] || return 1
  host=${host%%:*}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  path=${path%/}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  case "$host" in
    *[!a-z0-9.-]*|.*|*.|-*) return 1 ;;
  esac
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *[!A-Za-z0-9._/-]*|*//*|.*|*/.*) return 1 ;;
  esac
  FM_PR_BASE_URL_HOST=$host
  FM_PR_BASE_URL_PATH=$path
}

# Forge identities are compared case-insensitively: GitHub and GitLab both treat
# owner and repository names that way, so "Acme-Fleet/widget" and
# "acme-fleet/widget" name one repository and must never read as a mismatch.
fm_pr_base_identity_equal() {
  local a b
  local LC_ALL=C
  a=$(printf '%s\t%s' "${1-}" "${2-}" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s\t%s' "${3-}" "${4-}" | tr '[:upper:]' '[:lower:]')
  [ -n "${1-}" ] && [ -n "${2-}" ] && [ "$a" = "$b" ]
}

# Print the name of the remote in <dir> whose URL names <host>/<path>, or
# nothing. Preferring "origin" when several remotes carry the same URL keeps the
# answer stable for the common single-remote checkout.
fm_pr_base_remote_for_identity() {
  local dir=${1-} host=${2-} path=${3-} line name url match=
  while IFS= read -r line; do
    name=${line%% *}
    url=${line#* }
    name=${name#remote.}
    name=${name%.url}
    fm_pr_base_url_identity "$url" || continue
    fm_pr_base_identity_equal "$FM_PR_BASE_URL_HOST" "$FM_PR_BASE_URL_PATH" "$host" "$path" || continue
    if [ "$name" = origin ]; then
      printf '%s\n' "$name"
      return 0
    fi
    [ -n "$match" ] || match=$name
  done < <(git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

# Resolve the pull-request base repository a checkout is configured to target.
#
# Order:
#   1. `gh repo set-default`'s record - remote.<name>.gh-resolved. A value of
#      "base" means that remote IS the base; "OWNER/REPO" names a different
#      repository on that remote's host. This is the captain's explicit
#      declaration and outranks remote layout.
#   2. origin, the universal fallback and the only thing third-party tools read.
#
# Sets FM_PR_BASE_HOST, FM_PR_BASE_PATH, FM_PR_BASE_SOURCE (gh-resolved|origin)
# and FM_PR_BASE_REMOTE (the remote that actually fetches that repository, which
# is what supplies its remote-tracking refs; empty when no remote does).
fm_pr_base_resolve() {
  local dir=${1-} line name value url pass
  FM_PR_BASE_HOST=
  FM_PR_BASE_PATH=
  FM_PR_BASE_REMOTE=
  FM_PR_BASE_SOURCE=
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  # Two passes so an explicit "base" declaration wins over an "OWNER/REPO" one
  # regardless of the order git happens to print the config in.
  for pass in base repo; do
    while IFS= read -r line; do
      name=${line%% *}
      value=${line#* }
      name=${name#remote.}
      name=${name%.gh-resolved}
      url=$(git -C "$dir" config --get "remote.$name.url" 2>/dev/null) || url=
      fm_pr_base_url_identity "$url" || continue
      if [ "$pass" = base ]; then
        [ "$value" = base ] || continue
        FM_PR_BASE_HOST=$FM_PR_BASE_URL_HOST
        FM_PR_BASE_PATH=$FM_PR_BASE_URL_PATH
      else
        [ "$value" != base ] || continue
        # An OWNER/REPO record is validated through the same normalizer by
        # pairing it with its remote's host, so a malformed value is dropped
        # instead of becoming a bogus expectation.
        fm_pr_base_url_identity "https://$FM_PR_BASE_URL_HOST/$value" || continue
        FM_PR_BASE_HOST=$FM_PR_BASE_URL_HOST
        FM_PR_BASE_PATH=$FM_PR_BASE_URL_PATH
      fi
      FM_PR_BASE_SOURCE=gh-resolved
      break
    done < <(git -C "$dir" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null)
    [ -z "$FM_PR_BASE_SOURCE" ] || break
  done
  if [ -z "$FM_PR_BASE_SOURCE" ]; then
    url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || url=
    fm_pr_base_url_identity "$url" || return 1
    FM_PR_BASE_HOST=$FM_PR_BASE_URL_HOST
    FM_PR_BASE_PATH=$FM_PR_BASE_URL_PATH
    FM_PR_BASE_SOURCE=origin
  fi
  # Consumed by the sourcing scripts, not by this library.
  # shellcheck disable=SC2034
  FM_PR_BASE_REMOTE=$(fm_pr_base_remote_for_identity "$dir" "$FM_PR_BASE_HOST" "$FM_PR_BASE_PATH" || true)
}

# Print the default branch name a remote advertises, from its remote-tracking
# HEAD. Returns non-zero when the checkout has never recorded one - `git remote
# set-head <remote> --auto` is what records it, and bin/fm-pr-base.sh runs that.
fm_pr_base_default_branch() {
  local dir=${1-} remote=${2-} ref
  [ -n "$remote" ] || return 1
  ref=$(git -C "$dir" symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null) || return 1
  ref=${ref#"refs/remotes/$remote/"}
  [ -n "$ref" ] && [ "$ref" != "refs/remotes/$remote/HEAD" ] || return 1
  printf '%s\n' "$ref"
}

# Detect a branch cut from the WRONG repository's default branch.
#
# A pull request adds exactly the commits in <base-ref>..<rev>. When the branch
# was cut from the base repository's default branch, every one of those commits
# is the branch's own work. When it was cut from a DIFFERENT remote's default
# branch, that other branch's commits ride along - which is how a six-commit
# change opens as a 26-commit, 140-file pull request, and how merging it would
# sync two repositories as an unannounced side effect.
#
# So: count the commits the branch would add that are already contained in some
# other remote's default branch. Any such commit is imported history, not work.
#
# CUT FROM, NOT MERGED IN. Deliberately merging one repository's default branch
# into the other is a real task - it is how a fork ingests upstream - and its
# pull request legitimately carries those commits. The two are told apart by
# containment: a branch that was cut from the wrong default branch does not
# contain the base branch at all, while a branch that merged the other side in
# contains both. Only the first is reported.
#
# Sets FM_PR_BASE_FOREIGN_REMOTE/_COUNT/_IDENTITY and returns 0 when found.
fm_pr_base_foreign_commits() {
  local dir=${1-} base_remote=${2-} base_branch=${3-} rev=${4-}
  local base_ref total own foreign remote other_ref url best=0 line name
  FM_PR_BASE_FOREIGN_REMOTE=
  FM_PR_BASE_FOREIGN_COUNT=
  FM_PR_BASE_FOREIGN_IDENTITY=
  [ -n "$base_remote" ] && [ -n "$base_branch" ] || return 1
  base_ref="refs/remotes/$base_remote/$base_branch"
  git -C "$dir" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || return 1
  git -C "$dir" rev-parse --verify --quiet "$rev" >/dev/null 2>&1 || return 1
  # The branch already contains the base branch, so nothing rides along that the
  # branch did not deliberately take on.
  ! git -C "$dir" merge-base --is-ancestor "$base_ref" "$rev" >/dev/null 2>&1 || return 1
  total=$(git -C "$dir" rev-list --count "$base_ref..$rev" 2>/dev/null) || return 1
  [ "$total" -gt 0 ] 2>/dev/null || return 1
  while IFS= read -r line; do
    name=${line%% *}
    url=${line#* }
    name=${name#remote.}
    name=${name%.url}
    [ "$name" != "$base_remote" ] || continue
    remote=$name
    other_ref=$(fm_pr_base_default_branch "$dir" "$remote") || continue
    other_ref="refs/remotes/$remote/$other_ref"
    git -C "$dir" rev-parse --verify --quiet "$other_ref" >/dev/null 2>&1 || continue
    own=$(git -C "$dir" rev-list --count "$base_ref..$rev" --not "$other_ref" 2>/dev/null) || continue
    foreign=$((total - own))
    [ "$foreign" -gt "$best" ] || continue
    best=$foreign
    # Consumed by the sourcing scripts, not by this library.
    # shellcheck disable=SC2034
    FM_PR_BASE_FOREIGN_REMOTE=$remote
    # shellcheck disable=SC2034
    FM_PR_BASE_FOREIGN_COUNT=$foreign
    if fm_pr_base_url_identity "$url"; then
      # shellcheck disable=SC2034
      FM_PR_BASE_FOREIGN_IDENTITY="$FM_PR_BASE_URL_HOST/$FM_PR_BASE_URL_PATH"
    else
      # shellcheck disable=SC2034
      FM_PR_BASE_FOREIGN_IDENTITY=$url
    fi
  done < <(git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  [ "$best" -gt 0 ]
}
